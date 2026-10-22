import AppKit
import RVLCCore

/// Slim, accent-coloured slider cell used for the timeline and volume.
final class SlimSliderCell: NSSliderCell {
    var trackHeight: CGFloat = 4
    var knobDiameter: CGFloat = 12
    var showsKnobOnlyWhenActive = false
    var isHovered = false
    /// Position under the pointer (0…1), previewed on the track while hovering.
    var hoverFraction: Double?

    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let fraction = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        let x = bar.minX + CGFloat(fraction) * bar.width - knobDiameter / 2
        return NSRect(x: x, y: bar.midY - knobDiameter / 2, width: knobDiameter, height: knobDiameter)
    }

    override func barRect(flipped: Bool) -> NSRect {
        guard let controlView else { return .zero }
        let b = controlView.bounds.insetBy(dx: knobDiameter / 2, dy: 0)
        return NSRect(x: b.minX, y: b.midY - trackHeight / 2, width: b.width, height: trackHeight)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = barRect(flipped: flipped)
        let radius = bar.height / 2
        let enabled = isEnabled
        NSColor.tertiaryLabelColor.withAlphaComponent(enabled ? 0.35 : 0.15).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
        let hover = enabled ? hoverFraction.map { CGFloat(max(0, min(1, $0))) } : nil
        if let hover {
            // Preview of the span up to the pointer, under the played part.
            var preview = bar
            preview.size.width = bar.width * hover
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: preview, xRadius: radius, yRadius: radius).fill()
        }
        let fraction = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        var filled = bar
        filled.size.width = bar.width * CGFloat(max(0, min(1, fraction)))
        (enabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
        if let hover {
            // A thin marker at the exact point the bubble describes.
            let x = (bar.minX + bar.width * hover).rounded()
            NSColor.labelColor.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: bar.midY - 5, width: 2, height: 10), xRadius: 1, yRadius: 1).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        guard isEnabled, !showsKnobOnlyWhenActive || isHovered || isHighlighted else { return }
        let r = knobRect.insetBy(dx: 0.5, dy: 0.5)
        NSColor.white.setFill()
        let path = NSBezierPath(ovalIn: r)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        path.stroke()
    }
}

/// Timeline with scrubbing semantics: fast keyframe seeks while dragging,
/// one exact seek on release, and a hover preview of the time under the pointer.
final class TimelineSlider: NSSlider {
    /// (seconds, isFinal)
    var onScrub: ((Double, Bool) -> Void)?
    private(set) var isDragging = false
    private let bubble = TimeBubbleView()
    private var tracking: NSTrackingArea?
    /// Position the hover offset (“+1:05”) is measured from: the playback
    /// position, or where a drag started.
    private var referenceTime: Double?

    private var slim: SlimSliderCell { cell as! SlimSliderCell }

    override class var cellClass: AnyClass? {
        get { SlimSliderCell.self }
        set {}
    }

    init() {
        super.init(frame: .zero)
        let c = SlimSliderCell()
        c.showsKnobOnlyWhenActive = true
        cell = c
        minValue = 0
        maxValue = 1
        isContinuous = true
        refusesFirstResponder = true
        target = self
        action = #selector(valueChanged)
        setAccessibilityLabel("Playback position")
    }

    required init?(coder: NSCoder) { fatalError() }

    var duration: Double = 0 {
        didSet {
            maxValue = max(duration, 0.001)
            isEnabled = duration > 0
        }
    }

    /// Updates from the engine are ignored while the user drags.
    func setPosition(_ seconds: Double) {
        guard !isDragging else { return }
        doubleValue = seconds
        setAccessibilityValue("\(Timecode.formatClock(seconds: seconds)) of \(Timecode.formatClock(seconds: duration))")
    }

    @objc private func valueChanged() {
        // Keyboard and assistive-technology changes (VoiceOver increment/decrement,
        // AXValue) arrive here and seek exactly. Mouse input is handled below.
        onScrub?(doubleValue, true)
    }

    /// The single mapping from a horizontal position (slider coordinates) to a
    /// time, shared by the hover label, clicks and drags so that clicking goes to
    /// exactly the time the label showed.
    func seconds(atX x: CGFloat) -> Double {
        let bar = slim.barRect(flipped: isFlipped)
        let fraction = max(0, min(1, (x - bar.minX) / max(bar.width, 1)))
        return Double(fraction) * duration
    }

    /// Click anywhere on the bar to jump there; drag to scrub (fast keyframe
    /// seeks), release for one exact seek.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, duration > 0, let window else { return }
        isDragging = true
        referenceTime = doubleValue
        slim.isHovered = true
        var location = convert(event.locationInWindow, from: nil)
        var time = seconds(atX: location.x)
        doubleValue = time
        onScrub?(time, false)
        showHover(atX: location.x, time: time)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            location = convert(next.locationInWindow, from: nil)
            time = seconds(atX: location.x)
            doubleValue = time
            if next.type == .leftMouseUp { break }
            onScrub?(time, false)
            showHover(atX: location.x, time: time)
        }
        isDragging = false
        referenceTime = nil
        onScrub?(time, true)
        if bounds.contains(location) {
            showHover(atX: location.x, time: time)
        } else {
            slim.isHovered = false
            hideHover()
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        slim.isHovered = true
        needsDisplay = true
        // A quick pointer movement may produce only this event inside the thin bar,
        // so show the time immediately rather than waiting for a mouse-moved event.
        guard duration > 0, !isDragging else { return }
        let x = convert(event.locationInWindow, from: nil).x
        showHover(atX: x, time: seconds(atX: x))
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        slim.isHovered = false
        hideHover()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard duration > 0, !isDragging else { return }
        let x = convert(event.locationInWindow, from: nil).x
        showHover(atX: x, time: seconds(atX: x))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideHover() }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Hover time label

    /// Gap between the knob and the bubble's arrow tip, so the bubble never
    /// covers the bar or the pointer.
    static let hoverGap: CGFloat = 5

    /// Frame for the hover bubble, in `host` coordinates, centred on `x` and
    /// placed above the bar (clamped to the host's width).
    func hoverFrame(atX x: CGFloat, labelSize: NSSize, in host: NSView) -> NSRect {
        let bar = slim.barRect(flipped: isFlipped)
        let barInHost = host.convert(NSRect(x: x, y: bar.minY, width: 0, height: bar.height), from: self)
        let originX = max(4, min(host.bounds.width - labelSize.width - 4, barInHost.midX - labelSize.width / 2))
        let originY =
            host.isFlipped
            ? barInHost.minY - Self.hoverGap - labelSize.height - slim.knobDiameter / 2
            : barInHost.maxY + Self.hoverGap + slim.knobDiameter / 2
        return NSRect(x: originX, y: originY, width: labelSize.width, height: labelSize.height)
    }

    /// View that hosts floating overlays such as the hover label. The player sets
    /// this to its root view so the label floats above both the video and the
    /// control bar (never a split view, which would treat it as a new pane).
    weak var overlayHost: NSView?

    var hoverHost: NSView? {
        if let overlayHost { return overlayHost }
        // Standalone use (e.g. tests): the window content, unless it is a split view.
        if let content = window?.contentView, !(content is NSSplitView) { return content }
        return superview
    }

    private func showHover(atX x: CGFloat, time: Double) {
        guard let host = hoverHost else { return }
        if bubble.superview !== host {
            bubble.removeFromSuperview()
            host.addSubview(bubble, positioned: .above, relativeTo: nil)
        }
        let reference = referenceTime ?? doubleValue
        let delta = time - reference
        let deltaText = abs(delta) < 1 ? nil : (delta > 0 ? "+" : "−") + Timecode.formatClock(seconds: abs(delta))
        let size = bubble.configure(time: Timecode.formatClock(seconds: time), delta: deltaText)
        let frame = hoverFrame(atX: x, labelSize: size, in: host)
        bubble.frame = frame
        // The arrow points at the pointer even when the bubble is pushed in at an edge.
        bubble.arrowX = host.convert(NSPoint(x: x, y: 0), from: self).x - frame.minX
        slim.hoverFraction = duration > 0 ? time / duration : nil
        needsDisplay = true
        if bubble.isHidden {
            bubble.alphaValue = 0
            bubble.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                bubble.animator().alphaValue = 1
            }
        }
    }

    private func hideHover() {
        bubble.isHidden = true
        slim.hoverFraction = nil
        needsDisplay = true
    }

    /// Current hover time, offset text and bubble frame in window coordinates (for tests).
    var hoverState: (text: String, delta: String?, frameInWindow: NSRect)? {
        guard !bubble.isHidden, let host = bubble.superview else { return nil }
        return (bubble.timeLabel.stringValue, bubble.deltaText, host.convert(bubble.frame, to: nil))
    }
}

/// Floating bubble above the timeline: the time under the pointer, how far it
/// is from the current position, and an arrow pointing at that spot.
final class TimeBubbleView: NSView {
    let timeLabel = NSTextField(labelWithString: "")
    private let deltaLabel = NSTextField(labelWithString: "")
    private(set) var deltaText: String?
    /// Arrow tip position, in the bubble's coordinates.
    var arrowX: CGFloat = 0 { didSet { needsDisplay = true } }

    static let arrowHeight: CGFloat = 5
    private static let arrowHalfWidth: CGFloat = 6
    private static let radius: CGFloat = 7
    private static let padding = NSSize(width: 9, height: 5)
    private static let spacing: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.setAccessibilityLabel("Time under pointer")
        deltaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        deltaLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        deltaLabel.setAccessibilityLabel("Distance from the current position")
        addSubview(timeLabel)
        addSubview(deltaLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sets the text and returns the size the bubble needs, arrow included.
    func configure(time: String, delta: String?) -> NSSize {
        timeLabel.stringValue = time
        deltaText = delta
        deltaLabel.stringValue = delta ?? ""
        deltaLabel.isHidden = delta == nil
        timeLabel.sizeToFit()
        deltaLabel.sizeToFit()
        let p = Self.padding
        let contentHeight = max(timeLabel.frame.height, delta == nil ? 0 : deltaLabel.frame.height)
        let bodyY = Self.arrowHeight
        timeLabel.setFrameOrigin(NSPoint(x: p.width, y: bodyY + p.height + (contentHeight - timeLabel.frame.height) / 2))
        var width = p.width + timeLabel.frame.width
        if delta != nil {
            width += Self.spacing
            deltaLabel.setFrameOrigin(NSPoint(x: width, y: bodyY + p.height + (contentHeight - deltaLabel.frame.height) / 2))
            width += deltaLabel.frame.width
        }
        width += p.width
        needsDisplay = true
        return NSSize(width: width.rounded(.up), height: (contentHeight + 2 * p.height + Self.arrowHeight).rounded(.up))
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSRect(x: 0.5, y: Self.arrowHeight, width: bounds.width - 1, height: bounds.height - Self.arrowHeight - 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: Self.radius, yRadius: Self.radius)
        let tip = max(Self.radius + Self.arrowHalfWidth, min(bounds.width - Self.radius - Self.arrowHalfWidth, arrowX))
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: tip - Self.arrowHalfWidth, y: body.minY + 0.5))
        arrow.line(to: NSPoint(x: tip, y: 0))
        arrow.line(to: NSPoint(x: tip + Self.arrowHalfWidth, y: body.minY + 0.5))
        arrow.close()
        path.append(arrow)
        NSColor(white: 0.1, alpha: 0.92).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius - 0.5, yRadius: Self.radius - 0.5).stroke()
    }
}
