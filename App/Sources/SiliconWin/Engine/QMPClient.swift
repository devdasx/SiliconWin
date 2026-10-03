import Foundation

struct QMPError: LocalizedError {
    let className: String
    let message: String
    var errorDescription: String? { "\(message) (\(className))" }
}

/// Client for the QEMU Machine Protocol: JSON commands in, JSON replies and
/// asynchronous events out, one object per line.
final class QMPClient {
    typealias Completion = (Result<Any, Error>) -> Void

    private let socket: UnixSocket
    private let reader: LineReader
    private let lock = NSLock()
    private var pending: [Int: Completion] = [:]
    private var nextID = 1
    private var closed = false

    /// Called on a background thread for every QMP event (e.g. "SHUTDOWN", "RESET").
    var onEvent: ((String, [String: Any]) -> Void)?
    /// Called on a background thread when QEMU closes the connection.
    var onClose: (() -> Void)?

    private init(socket: UnixSocket) {
        self.socket = socket
        reader = LineReader(socket: socket)
    }

    /// Connects, negotiates capabilities and starts the reader thread.
    static func connect(path: String, timeout: TimeInterval) throws -> QMPClient {
        let client = QMPClient(socket: try UnixSocket.connect(path: path, timeout: timeout))
        _ = try client.reader.readLine()  // {"QMP": {"version": ...}}
        try client.socket.write(Data("{\"execute\":\"qmp_capabilities\"}\n".utf8))
        while true {
            let line = try client.reader.readLine()
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if object["return"] != nil { break }
            if let error = object["error"] as? [String: Any] {
                throw QMPError(className: error["class"] as? String ?? "Error", message: error["desc"] as? String ?? "")
            }
        }
        let thread = Thread { [client] in client.readLoop() }
        thread.name = "SiliconWin QMP"
        thread.start()
        return client
    }

    func send(_ command: String, _ arguments: [String: Any]? = nil, completion: Completion? = nil) {
        lock.lock()
        let id = nextID
        nextID += 1
        let isClosed = closed
        if let completion, !isClosed { pending[id] = completion }
        lock.unlock()
        if isClosed {
            completion?(.failure(SocketError.closed))
            return
        }

        var message: [String: Any] = ["execute": command, "id": id]
        if let arguments { message["arguments"] = arguments }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try socket.write(data)
        } catch {
            lock.lock()
            let handler = pending.removeValue(forKey: id)
            lock.unlock()
            handler?(.failure(error))
        }
    }

    @discardableResult
    func execute(_ command: String, _ arguments: [String: Any]? = nil) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            send(command, arguments) { continuation.resume(with: $0) }
        }
    }

    /// Presses and releases the given QEMU key codes together (e.g. ["ctrl", "alt", "delete"]).
    func sendKeys(_ codes: [String], holdMilliseconds: Int = 100) {
        send("send-key", [
            "keys": codes.map { ["type": "qcode", "data": $0] },
            "hold-time": holdMilliseconds,
        ])
    }

    func close() {
        socket.close()
    }

    private func readLoop() {
        while true {
            let line: String
            do {
                line = try reader.readLine()
            } catch {
                break
            }
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }

            if let event = object["event"] as? String {
                onEvent?(event, object["data"] as? [String: Any] ?? [:])
                continue
            }
            guard let id = object["id"] as? Int else { continue }
            lock.lock()
            let handler = pending.removeValue(forKey: id)
            lock.unlock()
            if let error = object["error"] as? [String: Any] {
                handler?(.failure(QMPError(className: error["class"] as? String ?? "Error",
                                           message: error["desc"] as? String ?? "Unknown error")))
            } else {
                handler?(.success(object["return"] ?? [:]))
            }
        }

        lock.lock()
        closed = true
        let handlers = pending.values
        pending.removeAll()
        lock.unlock()
        handlers.forEach { $0(.failure(SocketError.closed)) }
        onClose?()
    }
}

/// Line-based channel to the SiliconWin agent inside Windows (a virtio-serial
/// port named "org.siliconwin.agent.0").
final class AgentChannel: @unchecked Sendable {   // send() is thread-safe (socket write lock)
    private let socket: UnixSocket
    private let reader: LineReader

    /// Called on a background thread for each line Windows sends.
    var onLine: ((String) -> Void)?
    var onClose: (() -> Void)?

    private init(socket: UnixSocket) {
        self.socket = socket
        reader = LineReader(socket: socket)
    }

    static func connect(path: String, timeout: TimeInterval) throws -> AgentChannel {
        AgentChannel(socket: try UnixSocket.connect(path: path, timeout: timeout))
    }

    func start() {
        let thread = Thread { [self] in
            while true {
                guard let line = try? reader.readLine() else { break }
                if !line.isEmpty { onLine?(line) }
            }
            onClose?()
        }
        thread.name = "SiliconWin agent"
        thread.start()
    }

    func send(_ line: String) {
        try? socket.write(Data((line + "\n").utf8))
    }

    func close() { socket.close() }
}
