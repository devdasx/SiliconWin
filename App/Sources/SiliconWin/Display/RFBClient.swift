import CoreGraphics
import Foundation
import Metal

enum RFBError: LocalizedError {
    case refused(String)
    case unsupportedSecurity([UInt8])
    case authenticationFailed
    case protocolViolation(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason): return "The display server refused the connection: \(reason)"
        case .unsupportedSecurity(let types): return "Unsupported display security types \(types)"
        case .authenticationFailed: return "Display authentication failed."
        case .protocolViolation(let detail): return "Display protocol error: \(detail)"
        }
    }
}

/// The guest screen: BGRX pixels in shared memory that the RFB thread writes
/// and Metal samples directly (a linear texture on top of an MTLBuffer).
final class Framebuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let buffer: MTLBuffer
    let texture: MTLTexture

    var contents: UnsafeMutableRawPointer { buffer.contents() }

    init?(device: MTLDevice, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let alignment = max(64, device.minimumLinearTextureAlignment(for: .bgra8Unorm))
        let stride = (width * 4 + alignment - 1) / alignment * alignment
        guard let buffer = device.makeBuffer(length: stride * height, options: .storageModeShared) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = buffer.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: stride) else { return nil }
        self.width = width
        self.height = height
        bytesPerRow = stride
        self.buffer = buffer
        self.texture = texture
    }

    /// Snapshot of the screen as a CGImage (for thumbnails).
    func makeImage() -> CGImage? {
        let data = Data(bytes: contents, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Minimal RFB 3.8 client for QEMU's built-in VNC server on a Unix socket.
/// Uses raw encoding (fastest over a local socket), desktop resizing and the
/// QEMU extended key event (raw PC scan codes, so every keyboard layout works).
final class RFBClient {
    private enum Encoding {
        static let raw: Int32 = 0
        static let desktopSize: Int32 = -223
        static let qemuPointerMotion: Int32 = -257
        static let qemuExtendedKeyEvent: Int32 = -258
        static let ledState: Int32 = -261
        static let extendedDesktopSize: Int32 = -308
    }

    private let socket: UnixSocket
    private let reader: SocketReader
    private let device: MTLDevice
    private(set) var framebuffer: Framebuffer
    private let redrawLock = NSLock()
    private var redrawScheduled = false
    private var closed = false

    /// Main thread: the screen changed size (new pixel storage).
    var onResize: ((Framebuffer) -> Void)?
    /// Main thread: new pixels arrived (coalesced to one call per run loop pass).
    var onUpdate: (() -> Void)?
    /// Main thread: the connection ended.
    var onClose: ((Error?) -> Void)?

    init(socketPath: String, device: MTLDevice, timeout: TimeInterval = 15) throws {
        socket = try UnixSocket.connect(path: socketPath, timeout: timeout)
        reader = SocketReader(socket: socket)
        self.device = device

        // Protocol version
        _ = try reader.readData(12)
        try socket.write(Data("RFB 003.008\n".utf8))

        // Security handshake: QEMU offers "None" on a local socket.
        let typeCount = Int(try reader.readUInt8())
        if typeCount == 0 {
            let length = Int(try reader.readUInt32())
            throw RFBError.refused(String(decoding: try reader.readData(length), as: UTF8.self))
        }
        let types = [UInt8](try reader.readData(typeCount))
        guard types.contains(1) else { throw RFBError.unsupportedSecurity(types) }
        try socket.write(Data([1]))
        guard try reader.readUInt32() == 0 else { throw RFBError.authenticationFailed }

        // ClientInit (shared) / ServerInit
        try socket.write(Data([1]))
        let width = Int(try reader.readUInt16())
        let height = Int(try reader.readUInt16())
        try reader.skip(16)
        _ = try reader.readData(Int(try reader.readUInt32()))

        guard let framebuffer = Framebuffer(device: device, width: max(width, 1), height: max(height, 1)) else {
            throw RFBError.protocolViolation("cannot allocate a \(width)x\(height) screen")
        }
        self.framebuffer = framebuffer

        // SetPixelFormat: 32 bpp, depth 24, little endian, true colour, BGRX in memory.
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format.appendBigEndian(UInt16(255))
        format.appendBigEndian(UInt16(255))
        format.appendBigEndian(UInt16(255))
        format.append(contentsOf: [16, 8, 0, 0, 0, 0])
        try socket.write(format)

        let encodings: [Int32] = [Encoding.raw, Encoding.extendedDesktopSize, Encoding.desktopSize,
                                  Encoding.qemuExtendedKeyEvent, Encoding.ledState, Encoding.qemuPointerMotion]
        var setEncodings = Data([2, 0])
        setEncodings.appendBigEndian(UInt16(encodings.count))
        encodings.forEach { setEncodings.appendBigEndian($0) }
        try socket.write(setEncodings)
    }

    func start() {
        requestUpdate(incremental: false)
        let thread = Thread { [self] in run() }
        thread.name = "SiliconWin display"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func close() {
        socket.close()
    }

    // MARK: Input

    /// Key events are paced: QEMU's USB keyboard buffers only 16 events and
    /// Windows takes one per USB poll (~8 ms). Bursts (text expanders,
    /// automation, very fast typing) would overflow it and lose key-ups, which
    /// leaves keys stuck and auto-repeating. Normal typing is never delayed.
    private let keyQueue = DispatchQueue(label: "SiliconWin keyboard", qos: .userInteractive)
    private var lastKeyEvent = DispatchTime(uptimeNanoseconds: 0)   // only touched on keyQueue
    private static let keySpacing: UInt64 = 10_000_000              // 10 ms

    /// QEMU extended key event: `scancode` is the PC/XT scan code (0x80 bit = E0 prefix).
    func sendKey(scancode: UInt32, down: Bool) {
        var message = Data([255, 0])
        message.appendBigEndian(UInt16(down ? 1 : 0))
        message.appendBigEndian(UInt32(0))
        message.appendBigEndian(scancode)
        keyQueue.async { [weak self] in
            guard let self else { return }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- self.lastKeyEvent.uptimeNanoseconds
            if elapsed < Self.keySpacing {
                usleep(useconds_t((Self.keySpacing - elapsed) / 1000))
            }
            self.send(message)
            self.lastKeyEvent = .now()
        }
    }

    /// Absolute pointer position (USB tablet) with the RFB button mask.
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        var message = Data([5, buttons])
        message.appendBigEndian(UInt16(clamping: max(0, x)))
        message.appendBigEndian(UInt16(clamping: max(0, y)))
        send(message)
    }

    private func requestUpdate(incremental: Bool) {
        var message = Data([3, incremental ? 1 : 0])
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(clamping: framebuffer.width))
        message.appendBigEndian(UInt16(clamping: framebuffer.height))
        send(message)
    }

    private func send(_ data: Data) {
        try? socket.write(data)
    }

    // MARK: Server messages

    private func run() {
        var failure: Error?
        do {
            while true {
                let type = try reader.readUInt8()
                switch type {
                case 0:
                    try readFramebufferUpdate()
                case 1:  // SetColourMapEntries (unused with true colour)
                    try reader.skip(3)
                    let count = Int(try reader.readUInt16())
                    try reader.skip(count * 6)
                case 2:  // Bell
                    break
                case 3:  // ServerCutText
                    try reader.skip(3)
                    let length = try reader.readInt32()
                    try reader.skip(Int(length.magnitude))
                default:
                    throw RFBError.protocolViolation("unknown message type \(type)")
                }
            }
        } catch SocketError.closed {
            failure = nil
        } catch {
            failure = error
        }
        DispatchQueue.main.async { [self] in onClose?(failure) }
    }

    private func readFramebufferUpdate() throws {
        try reader.skip(1)
        let count = Int(try reader.readUInt16())
        var drew = false
        for _ in 0..<count {
            let x = Int(try reader.readUInt16())
            let y = Int(try reader.readUInt16())
            let width = Int(try reader.readUInt16())
            let height = Int(try reader.readUInt16())
            let encoding = try reader.readInt32()

            switch encoding {
            case Encoding.raw:
                try readRaw(x: x, y: y, width: width, height: height)
                drew = true
            case Encoding.desktopSize:
                resize(width: width, height: height)
            case Encoding.extendedDesktopSize:
                let screens = Int(try reader.readUInt8())
                try reader.skip(3 + screens * 16)
                resize(width: width, height: height)
            case Encoding.ledState:
                _ = try reader.readUInt8()
            case Encoding.qemuExtendedKeyEvent, Encoding.qemuPointerMotion:
                break
            default:
                throw RFBError.protocolViolation("unexpected encoding \(encoding)")
            }
        }
        if drew { scheduleRedraw() }
        requestUpdate(incremental: true)
    }

    private func readRaw(x: Int, y: Int, width: Int, height: Int) throws {
        let screen = framebuffer
        guard width > 0, height > 0 else { return }
        guard x + width <= screen.width, y + height <= screen.height else {
            try reader.skip(width * height * 4)
            return
        }
        let rowBytes = width * 4
        if x == 0, width == screen.width, rowBytes == screen.bytesPerRow {
            try reader.readExactly(into: screen.contents + y * screen.bytesPerRow, count: rowBytes * height)
            return
        }
        for row in 0..<height {
            try reader.readExactly(into: screen.contents + (y + row) * screen.bytesPerRow + x * 4, count: rowBytes)
        }
    }

    private func resize(width: Int, height: Int) {
        guard width > 0, height > 0, width != framebuffer.width || height != framebuffer.height,
              let resized = Framebuffer(device: device, width: width, height: height) else { return }
        framebuffer = resized
        DispatchQueue.main.async { [self] in onResize?(resized) }
    }

    private func scheduleRedraw() {
        redrawLock.lock()
        let alreadyScheduled = redrawScheduled
        redrawScheduled = true
        redrawLock.unlock()
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [self] in
            redrawLock.lock()
            redrawScheduled = false
            redrawLock.unlock()
            onUpdate?()
        }
    }
}
