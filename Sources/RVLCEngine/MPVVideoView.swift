import AppKit
import CMpv
import OpenGL.GL
import OpenGL.GL3
import os

// libmpv's embedding API on macOS is OpenGL-based (the `--wid` option is not
// supported there). Apple deprecates OpenGL but it remains functional and is
// what IINA and other libmpv front-ends use. Silence the deprecation noise in
// one place by keeping all GL calls in this file.

private func mpvGetProcAddress(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name else { return nil }
    let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
    let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

/// Core Animation OpenGL layer that renders libmpv frames.
final class MPVVideoLayer: CAOpenGLLayer {
    private weak var player: MPVPlayer?
    private var renderContext: OpaquePointer?
    private var cglContext: CGLContextObj?
    /// Every libmpv render call and every GL draw happens on this queue
    /// (render.h allows only one render call at a time, with the context current).
    private let renderQueue = DispatchQueue(label: "rvlc.mpv.render")
    private let renderQueueKey = DispatchSpecificKey<Bool>()
    private var forceRender = true
    private var isUninitialized = false
    /// C string for MPV_RENDER_PARAM_API_TYPE; must outlive the call, so it is never freed.
    private static let apiTypeOpenGL = strdup(MPV_RENDER_API_TYPE_OPENGL)
    private let log = Logger(subsystem: "RVLCPlayer", category: "video")
    var onRenderFailure: ((String) -> Void)?

    private var pixelFormat: CGLPixelFormatObj?

    init(player: MPVPlayer) {
        self.player = player
        super.init()
        renderQueue.setSpecific(key: renderQueueKey, value: true)
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        // Create the GL context and libmpv render context eagerly: libmpv sets up
        // its video output when a file loads, and a missing render context at
        // that moment would disable video for the whole file.
        pixelFormat = Self.choosePixelFormat()
        if let pixelFormat {
            var ctx: CGLContextObj?
            if CGLCreateContext(pixelFormat, nil, &ctx) == kCGLNoError, let ctx {
                var swapInterval: GLint = 1
                CGLSetParameter(ctx, kCGLCPSwapInterval, &swapInterval)
                CGLEnable(ctx, kCGLCEMPEngine)
                CGLSetCurrentContext(ctx)
                cglContext = ctx
                createRenderContext()
                CGLSetCurrentContext(nil)
            }
        }
    }

    override init(layer: Any) {
        // Presentation-layer copy made by Core Animation.
        let other = layer as? MPVVideoLayer
        player = other?.player
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func choosePixelFormat() -> CGLPixelFormatObj? {
        let candidates: [[CGLPixelFormatAttribute]] = [
            [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
                kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers, kCGLPFASupportsAutomaticGraphicsSwitching,
                _CGLPixelFormatAttribute(0),
            ],
            [
                kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue), kCGLPFADoubleBuffer,
                _CGLPixelFormatAttribute(0),
            ],
        ]
        for attributes in candidates {
            var pixelFormat: CGLPixelFormatObj?
            var count: GLint = 0
            if CGLChoosePixelFormat(attributes, &pixelFormat, &count) == kCGLNoError, let pixelFormat {
                return pixelFormat
            }
        }
        return nil
    }

    // Core Animation receives its own retained reference and releases it itself.
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        if let pixelFormat { return CGLRetainPixelFormat(pixelFormat) }
        return super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        if let cglContext { return CGLRetainContext(cglContext) }
        return super.copyCGLContext(forPixelFormat: pf)
    }

    /// Core Animation may ask for a redraw on the main thread (resize, full screen);
    /// route every draw through the render queue so libmpv is never entered twice.
    override func display() {
        if DispatchQueue.getSpecific(key: renderQueueKey) == true {
            guard !isUninitialized else { return }
            super.display()
        } else {
            renderQueue.async { [weak self] in
                guard let self, !self.isUninitialized else { return }
                self.display()
                CATransaction.flush()
            }
        }
    }

    private func createRenderContext() {
        guard renderContext == nil, let player else { return }
        let apiType = UnsafeMutableRawPointer(Self.apiTypeOpenGL)
        var initParams = mpv_opengl_init_params(get_proc_address: mpvGetProcAddress, get_proc_address_ctx: nil)
        var ctx: OpaquePointer?
        let rc = withUnsafeMutablePointer(to: &initParams) { initPtr -> Int32 in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param(),
            ]
            return mpv_render_context_create(&ctx, player.handle, &params)
        }
        guard rc >= 0, let ctx else {
            let message = String(cString: mpv_error_string(rc))
            log.error("mpv_render_context_create failed: \(message, privacy: .public)")
            DispatchQueue.main.async { self.onRenderFailure?(message) }
            return
        }
        renderContext = ctx
        mpv_render_context_set_update_callback(
            ctx,
            { context in
                guard let context else { return }
                let layer = Unmanaged<MPVVideoLayer>.fromOpaque(context).takeUnretainedValue()
                layer.requestRender()
            }, Unmanaged.passUnretained(self).toOpaque())
    }

    func requestRender(force: Bool = false) {
        renderQueue.async { [weak self] in
            guard let self, !self.isUninitialized else { return }
            if force { self.forceRender = true }
            self.display()
            CATransaction.flush()
        }
    }

    override func canDraw(
        inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        guard let renderContext else { return true }
        if forceRender { return true }
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }
        return (mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)) != 0
    }

    override func draw(
        inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        CGLLockContext(ctx)
        defer { CGLUnlockContext(ctx) }
        CGLSetCurrentContext(ctx)
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        forceRender = false
        guard let renderContext else { glFlush(); return }
        var fboBinding: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fboBinding)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var fbo = mpv_opengl_fbo(fbo: Int32(fboBinding), w: Int32(viewport[2]), h: Int32(viewport[3]), internal_format: 0)
        var flipY: Int32 = 1
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        glFlush()
    }

    /// Must be called before the player's libmpv instance is destroyed.
    func uninitialize() {
        renderQueue.sync {
            isUninitialized = true
            guard let renderContext else { return }
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            if let cglContext {
                CGLLockContext(cglContext)
                CGLSetCurrentContext(cglContext)
                mpv_render_context_free(renderContext)
                CGLUnlockContext(cglContext)
            } else {
                mpv_render_context_free(renderContext)
            }
            self.renderContext = nil
            if let cglContext { CGLReleaseContext(cglContext) }
            if let pixelFormat { CGLReleasePixelFormat(pixelFormat) }
            self.cglContext = nil
            self.pixelFormat = nil
        }
    }
}

/// An `NSView` that shows libmpv video output.
public final class MPVVideoView: NSView {
    private let videoLayer: MPVVideoLayer
    public var onRenderFailure: ((String) -> Void)? {
        get { videoLayer.onRenderFailure }
        set { videoLayer.onRenderFailure = newValue }
    }

    public init(player: MPVPlayer) {
        videoLayer = MPVVideoLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Video")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func makeBackingLayer() -> CALayer { videoLayer }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.requestRender(force: true)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        videoLayer.requestRender(force: true)
    }

    public override var isOpaque: Bool { true }

    /// Frees the libmpv render context. Call before `MPVPlayer.shutdown()`.
    public func uninitialize() { videoLayer.uninitialize() }
}
