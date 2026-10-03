import AppKit
import MetalKit

/// Shows the guest screen and forwards keyboard and mouse input to it.
final class VMDisplayView: MTKView, MTKViewDelegate {
    /// Pixels to draw (nil while the VM is off).
    var framebuffer: Framebuffer? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Where input goes.
    var client: RFBClient? {
        didSet { keyboard.releaseAll() }
    }

    let keyboard = KeyboardTranslator()

    /// Files dropped from Finder onto the screen.
    var onFilesDropped: (([URL]) -> Void)?

    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var linearSampler: MTLSamplerState?
    private var nearestSampler: MTLSamplerState?
    private var buttons: UInt8 = 0
    private var scrollAccumulator = CGPoint.zero
    private var keyUpMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    private static let blankCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    init() {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
        setUpPipeline()
        keyboard.send = { [weak self] code, down in
            self?.client?.sendKey(scancode: code, down: down)
        }
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFilesDropped != nil && client != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: Rendering

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut screenVertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 positions[4] = { float2(rect.x, rect.y), float2(rect.z, rect.y), float2(rect.x, rect.w), float2(rect.z, rect.w) };
        float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
        VertexOut out;
        out.position = float4(positions[id], 0, 1);
        out.uv = uvs[id];
        return out;
    }

    fragment float4 screenFragment(VertexOut in [[stage_in]], texture2d<float> screen [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(screen.sample(s, in.uv).rgb, 1.0);
    }
    """

    private func setUpPipeline() {
        guard let device else { return }
        commandQueue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("SiliconWin: Metal pipeline failed: \(error)")
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        linearSampler = device.makeSamplerState(descriptor: samplerDescriptor)
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        nearestSampler = device.makeSamplerState(descriptor: samplerDescriptor)
    }

    /// Aspect-fit rectangle for the guest screen inside `container`.
    private static func fitRect(container: CGSize, content: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / content.width, container.height / content.height)
        let width = (content.width * scale).rounded()
        let height = (content.height * scale).rounded()
        return CGRect(x: ((container.width - width) / 2).rounded(.down),
                      y: ((container.height - height) / 2).rounded(.down),
                      width: width, height: height)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        if let screen = framebuffer, let pipeline {
            let size = drawableSize
            let content = CGSize(width: screen.width, height: screen.height)
            let rect = Self.fitRect(container: size, content: content)
            var ndc = SIMD4<Float>(Float(rect.minX / size.width * 2 - 1), Float(rect.minY / size.height * 2 - 1),
                                   Float(rect.maxX / size.width * 2 - 1), Float(rect.maxY / size.height * 2 - 1))
            // Pixel-exact scaling (1×, 2×, …) stays crisp with nearest sampling.
            let scale = rect.width / content.width
            let integerScale = scale >= 1 && abs(scale - scale.rounded()) < 0.002
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&ndc, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(screen.texture, index: 0)
            encoder.setFragmentSamplerState(integerScale ? nearestSampler : linearSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        installKeyUpMonitor()
        return true
    }

    override func resignFirstResponder() -> Bool {
        keyboard.releaseAll()
        releaseButtons()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.keyboard.releaseAll()
            self?.releaseButtons()
        }
        updateTrackingAreas()
    }

    /// AppKit swallows key-up events while ⌘ is held; catch them here so the
    /// guest sees every release.
    private func installKeyUpMonitor() {
        guard keyUpMonitor == nil else { return }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self, self.window?.firstResponder === self, event.window === self.window else { return event }
            self.keyboard.keyUp(event)
            return nil
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard client != nil else { return }
        keyboard.keyDown(event)
    }

    override func keyUp(with event: NSEvent) {
        keyboard.keyUp(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard client != nil else { return }
        keyboard.flagsChanged(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, client != nil else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Shortcuts the Mac app keeps for itself.
        if flags == [.command] && (key == "q" || key == "h") { return super.performKeyEquivalent(with: event) }
        if flags.contains([.command, .control]) && key == "f" { return super.performKeyEquivalent(with: event) }
        if flags.contains([.command, .option]) && (key == "\u{1b}" || key == "q") { return super.performKeyEquivalent(with: event) }
        keyboard.keyDown(event)
        return true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        // Windows draws its own pointer, so hide the Mac one over the screen.
        guard let screen = framebuffer else { return }
        let rect = Self.fitRect(container: bounds.size, content: CGSize(width: screen.width, height: screen.height))
        addCursorRect(rect, cursor: Self.blankCursor)
    }

    private func guestPosition(for event: NSEvent) -> (Int, Int)? {
        guard let screen = framebuffer else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let rect = Self.fitRect(container: bounds.size, content: CGSize(width: screen.width, height: screen.height))
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (point.x - rect.minX) / rect.width * CGFloat(screen.width)
        let y = (rect.maxY - point.y) / rect.height * CGFloat(screen.height)
        return (Int(min(max(x, 0), CGFloat(screen.width - 1))), Int(min(max(y, 0), CGFloat(screen.height - 1))))
    }

    private func sendPointer(_ event: NSEvent) {
        guard let client, let (x, y) = guestPosition(for: event) else { return }
        client.sendPointer(x: x, y: y, buttons: buttons)
    }

    private func button(_ mask: UInt8, down: Bool, _ event: NSEvent) {
        if down { buttons |= mask } else { buttons &= ~mask }
        sendPointer(event)
    }

    private func releaseButtons() {
        guard buttons != 0 else { return }
        buttons = 0
        if let event = NSApp.currentEvent { sendPointer(event) }
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(0x01, down: true, event)
    }

    override func mouseUp(with event: NSEvent) { button(0x01, down: false, event) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        button(0x04, down: true, event)
    }

    override func rightMouseUp(with event: NSEvent) { button(0x04, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { button(0x02, down: true, event) }
    override func otherMouseUp(with event: NSEvent) { button(0x02, down: false, event) }

    override func scrollWheel(with event: NSEvent) {
        guard let client, let (x, y) = guestPosition(for: event) else { return }
        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {  // trackpads report pixels
            dx /= 16
            dy /= 16
        }
        scrollAccumulator.x += dx
        scrollAccumulator.y += dy

        func click(_ mask: UInt8) {
            client.sendPointer(x: x, y: y, buttons: buttons | mask)
            client.sendPointer(x: x, y: y, buttons: buttons)
        }
        while scrollAccumulator.y >= 1 { click(0x08); scrollAccumulator.y -= 1 }    // wheel up
        while scrollAccumulator.y <= -1 { click(0x10); scrollAccumulator.y += 1 }   // wheel down
        while scrollAccumulator.x >= 1 { click(0x20); scrollAccumulator.x -= 1 }    // wheel left
        while scrollAccumulator.x <= -1 { click(0x40); scrollAccumulator.x += 1 }   // wheel right
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = .zero }
    }
}
