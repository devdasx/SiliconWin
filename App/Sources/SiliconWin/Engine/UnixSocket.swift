import Darwin
import Foundation

enum SocketError: LocalizedError {
    case pathTooLong(String)
    case connectFailed(String, Int32)
    case closed
    case io(Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): return "Socket path is too long: \(path)"
        case .connectFailed(let path, let code): return "Could not connect to \(path): \(String(cString: strerror(code)))"
        case .closed: return "The connection was closed."
        case .io(let code): return "Socket error: \(String(cString: strerror(code)))"
        }
    }
}

/// Blocking AF_UNIX stream socket (QEMU's QMP, VNC and agent channels).
final class UnixSocket {
    let fd: Int32
    private let stateLock = NSLock()
    private var isClosed = false
    private let writeLock = NSLock()

    private init(fd: Int32) { self.fd = fd }

    deinit { close() }

    static func connect(path: String) throws -> UnixSocket {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.io(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw SocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.connectFailed(path, code)
        }
        return UnixSocket(fd: fd)
    }

    /// Keeps retrying while QEMU is still creating the socket.
    static func connect(path: String, timeout: TimeInterval) throws -> UnixSocket {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                return try connect(path: path)
            } catch {
                if Date() > deadline { throw error }
                usleep(50_000)
            }
        }
    }

    func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw SocketError.io(errno)
                }
                offset += written
            }
        }
    }

    /// Reads at least one byte; throws `SocketError.closed` at end of stream.
    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        while true {
            let count = Darwin.read(fd, buffer, maxLength)
            if count > 0 { return count }
            if count == 0 { throw SocketError.closed }
            if errno == EINTR { continue }
            throw SocketError.io(errno)
        }
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

/// Buffered big-endian reader on top of a `UnixSocket` (used by the RFB client).
final class SocketReader {
    private let socket: UnixSocket
    private let capacity: Int
    private let buffer: UnsafeMutableRawPointer
    private var start = 0
    private var end = 0

    init(socket: UnixSocket, capacity: Int = 4 << 20) {
        self.socket = socket
        self.capacity = capacity
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { buffer.deallocate() }

    func readExactly(into destination: UnsafeMutableRawPointer, count: Int) throws {
        var copied = 0
        while copied < count {
            if start < end {
                let chunk = min(end - start, count - copied)
                memcpy(destination + copied, buffer + start, chunk)
                start += chunk
                copied += chunk
            } else if count - copied >= capacity / 2 {
                // Big payloads go straight into the destination.
                copied += try socket.read(into: destination + copied, maxLength: count - copied)
            } else {
                start = 0
                end = try socket.read(into: buffer, maxLength: capacity)
            }
        }
    }

    func skip(_ count: Int) throws {
        var remaining = count
        while remaining > 0 {
            if start < end {
                let chunk = min(end - start, remaining)
                start += chunk
                remaining -= chunk
            } else {
                start = 0
                end = try socket.read(into: buffer, maxLength: capacity)
            }
        }
    }

    func readUInt8() throws -> UInt8 {
        var value: UInt8 = 0
        try readExactly(into: &value, count: 1)
        return value
    }

    func readUInt16() throws -> UInt16 {
        var value: UInt16 = 0
        try readExactly(into: &value, count: 2)
        return UInt16(bigEndian: value)
    }

    func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        try readExactly(into: &value, count: 4)
        return UInt32(bigEndian: value)
    }

    func readInt32() throws -> Int32 { Int32(bitPattern: try readUInt32()) }

    func readData(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try readExactly(into: $0.baseAddress!, count: count) }
        return data
    }
}

/// Reads newline-terminated messages (QMP and the guest agent are line based).
final class LineReader {
    private let socket: UnixSocket
    private var pending = Data()
    private var chunk = [UInt8](repeating: 0, count: 65536)

    init(socket: UnixSocket) { self.socket = socket }

    func readLine() throws -> String {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let count = try chunk.withUnsafeMutableBytes { try socket.read(into: $0.baseAddress!, maxLength: $0.count) }
            pending.append(contentsOf: chunk[0..<count])
        }
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: Int32) {
        appendBigEndian(UInt32(bitPattern: value))
    }
}
