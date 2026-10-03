import Foundation

/// Downloads Windows installation images straight onto the library drive.
///
/// URLSession download tasks would stage multi-gigabyte files in the system
/// temporary folder on the internal disk first, so the engine streams the
/// bytes of a data task into "<name>.part" on the destination drive instead
/// and resumes partial files with HTTP range requests.
@MainActor
final class DownloadCenter: ObservableObject {
    static let shared = DownloadCenter()

    struct Item: Identifiable, Equatable {
        enum Status: Equatable {
            case downloading
            case finished
            case failed(String)
        }

        let id: UUID
        let fileName: String
        let destination: URL
        var received: Int64
        var expected: Int64
        var bytesPerSecond: Double
        var status: Status

        var fraction: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
    }

    @Published private(set) var items: [Item] = []

    private lazy var engine = DownloadEngine { [weak self] update in
        Task { @MainActor in self?.apply(update) }
    }

    func item(_ id: UUID?) -> Item? { items.first { $0.id == id } }

    /// Starts (or resumes) downloading `url` into `folder`; returns the item ID.
    @discardableResult
    func download(_ url: URL, into folder: URL) -> UUID {
        let name = url.lastPathComponent.isEmpty ? "Windows.iso" : url.lastPathComponent
        let finalURL = folder.appendingPathComponent(name)
        if let existing = items.first(where: { $0.destination == finalURL && $0.status == .downloading }) {
            return existing.id
        }
        let id = UUID()
        if FileManager.default.fileExists(atPath: finalURL.path) {
            let size = Int64((try? finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            items.append(Item(id: id, fileName: name, destination: finalURL, received: size, expected: size,
                              bytesPerSecond: 0, status: .finished))
            return id
        }
        items.append(Item(id: id, fileName: name, destination: finalURL, received: 0, expected: -1,
                          bytesPerSecond: 0, status: .downloading))
        engine.start(id: id, url: url, finalURL: finalURL)
        return id
    }

    func cancel(_ id: UUID) {
        engine.cancel(id: id)
    }

    private func apply(_ update: DownloadEngine.Update) {
        guard let index = items.firstIndex(where: { $0.id == update.id }) else { return }
        items[index].received = update.received
        items[index].expected = update.expected
        items[index].bytesPerSecond = update.bytesPerSecond
        switch update.result {
        case .none: items[index].status = .downloading
        case .success?: items[index].status = .finished
        case .failure(let message)?: items[index].status = .failed(message)
        }
    }
}

/// URLSession delegate doing the actual transfers on its own serial queue.
final class DownloadEngine: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Update {
        enum Result { case success, failure(String) }
        let id: UUID
        let received: Int64
        let expected: Int64
        let bytesPerSecond: Double
        let result: Result?
    }

    private final class Transfer {
        let id: UUID
        let partURL: URL
        let finalURL: URL
        var handle: FileHandle?
        var received: Int64 = 0
        var expected: Int64 = -1
        var lastReport = Date()
        var lastReportedBytes: Int64 = 0
        var speed = 0.0

        init(id: UUID, partURL: URL, finalURL: URL) {
            self.id = id
            self.partURL = partURL
            self.finalURL = finalURL
        }
    }

    private let report: (Update) -> Void
    private let queue = OperationQueue()
    private var session: URLSession!
    private var transfers: [Int: Transfer] = [:]   // only touched on `queue`
    private var tasks: [UUID: URLSessionTask] = [:]

    init(report: @escaping (Update) -> Void) {
        self.report = report
        super.init()
        queue.maxConcurrentOperationCount = 1
        queue.name = "SiliconWin downloads"
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func start(id: UUID, url: URL, finalURL: URL) {
        queue.addOperation { [self] in
            let partURL = finalURL.deletingLastPathComponent().appendingPathComponent(finalURL.lastPathComponent + ".part")
            try? FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            let transfer = Transfer(id: id, partURL: partURL, finalURL: finalURL)
            transfer.received = Int64((try? partURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
            if transfer.received > 0 {
                request.setValue("bytes=\(transfer.received)-", forHTTPHeaderField: "Range")
            }
            let task = session.dataTask(with: request)
            transfers[task.taskIdentifier] = transfer
            tasks[id] = task
            task.resume()
        }
    }

    func cancel(id: UUID) {
        queue.addOperation { [self] in tasks[id]?.cancel() }
    }

    private func send(_ transfer: Transfer, _ result: Update.Result?) {
        report(Update(id: transfer.id, received: transfer.received, expected: transfer.expected,
                      bytesPerSecond: result == nil ? transfer.speed : 0, result: result))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfers[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: transfer.partURL)
            switch http.statusCode {
            case 206:
                try handle.seekToEnd()
            case 200:
                try handle.truncate(atOffset: 0)
                transfer.received = 0
            default:
                try? handle.close()
                completionHandler(.cancel)
                send(transfer, .failure("The download server answered with HTTP \(http.statusCode). The link may have expired; get a new one from Microsoft."))
                return
            }
            transfer.handle = handle
            transfer.lastReportedBytes = transfer.received
            transfer.expected = http.expectedContentLength > 0 ? transfer.received + http.expectedContentLength : -1
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            send(transfer, .failure(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfers[dataTask.taskIdentifier], let handle = transfer.handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            send(transfer, .failure(error.localizedDescription))
            return
        }
        transfer.received += Int64(data.count)
        let now = Date()
        let elapsed = now.timeIntervalSince(transfer.lastReport)
        if elapsed >= 0.5 {
            transfer.speed = Double(transfer.received - transfer.lastReportedBytes) / elapsed
            transfer.lastReport = now
            transfer.lastReportedBytes = transfer.received
            send(transfer, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = transfers.removeValue(forKey: task.taskIdentifier) else { return }
        tasks[transfer.id] = nil
        try? transfer.handle?.close()
        transfer.handle = nil
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            send(transfer, .failure(cancelled ? "Cancelled" : error.localizedDescription))
            return
        }
        do {
            try? FileManager.default.removeItem(at: transfer.finalURL)
            try FileManager.default.moveItem(at: transfer.partURL, to: transfer.finalURL)
            transfer.expected = transfer.received
            send(transfer, .success)
        } catch {
            send(transfer, .failure(error.localizedDescription))
        }
    }
}
