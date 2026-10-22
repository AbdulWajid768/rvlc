// End-to-end test driver for RVLC.
//
// Launches the real application (normally the packaged .app) with an isolated
// profile and drives it like a user through the macOS Accessibility API:
// pressing buttons, typing keys, using menus, opening files through Launch
// Services and handling the save panel. Results are checked through what the
// user can see: labels, on-screen messages, window state and screenshots.
//
// Requires: Accessibility permission for the terminal running it, ffmpeg.
// Usage (see scripts/run-e2e.sh):
//   E2EDriver <path to RVLC.app> <fixtures dir> <data dir>

import AppKit
import ApplicationServices

// MARK: - Reporting

var failures: [String] = []
var passes = 0
/// Set once the app is launched, so failures can record focus diagnostics.
var diagnostics: (() -> String)?

func log(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passes += 1
        log("  ✔ \(name)")
    } else {
        var d = detail()
        if let extra = diagnostics?() { d += (d.isEmpty ? "" : "; ") + extra }
        failures.append(name + (d.isEmpty ? "" : " — \(d)"))
        log("  ✘ \(name)\(d.isEmpty ? "" : " — \(d)")")
    }
}

func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

@discardableResult
func waitFor(_ timeout: Double = 8, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        pump(0.1)
    }
    return condition()
}

// MARK: - Accessibility helpers

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
func role(_ el: AXUIElement) -> String { str(el, kAXRoleAttribute) ?? "" }
func children(_ el: AXUIElement) -> [AXUIElement] { attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

/// All strings an element exposes (title, description, value, help).
func texts(_ el: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].compactMap { str(el, $0) }
}

func descendants(_ root: AXUIElement, limit: Int = 6000) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue = [root]
    while !queue.isEmpty, result.count < limit {
        let el = queue.removeFirst()
        result.append(el)
        queue.append(contentsOf: children(el))
    }
    return result
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func press(_ el: AXUIElement) { AXUIElementPerformAction(el, kAXPressAction as CFString) }

func setValue(_ el: AXUIElement, _ value: Any) -> AXError {
    AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
}

final class AppUnderTest {
    let process: Process
    let pid: pid_t
    let ax: AXUIElement
    let appURL: URL

    init(appURL: URL, file: URL?, dataDir: URL, reset: Bool, logURL: URL) throws {
        self.appURL = appURL
        process = Process()
        process.executableURL = appURL.appendingPathComponent("Contents/MacOS/RVLCPlayer")
        process.arguments = file.map { [$0.path] } ?? []
        var env = ProcessInfo.processInfo.environment
        env["RVLC_DATA_DIR"] = dataDir.path
        env["RVLC_RESET"] = reset ? "1" : "0"
        process.environment = env
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        handle.seekToEndOfFile()
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        pid = process.processIdentifier
        ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 5)
    }

    var running: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }

    /// Brings the app to the front and waits until it really is active, so
    /// keystrokes reach it even if another app took focus during the run.
    func activate() {
        if running?.isActive == true { return }
        for _ in 0..<3 {
            running?.activate(options: [.activateAllWindows])
            if waitFor(2, { running?.isActive == true }) { break }
        }
        pump(0.2)
    }

    /// Who had focus when a check failed (to tell app bugs from interference).
    func focusReport() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        return "frontmost: \(front), app active: \(running?.isActive == true), windows: \(windows.count)"
    }

    var windows: [AXUIElement] { attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? [] }

    func window(titled title: String) -> AXUIElement? { windows.first { str($0, kAXTitleAttribute) == title } }

    /// The player window (the one containing the timeline).
    var mainWindow: AXUIElement? {
        windows.first { w in descendants(w, limit: 1500).contains { role($0) == kAXSliderRole && texts($0).contains("Playback position") } }
    }

    func find(_ predicate: (AXUIElement) -> Bool, in root: AXUIElement? = nil, timeout: Double = 5) -> AXUIElement? {
        var found: AXUIElement?
        waitFor(timeout) {
            let roots = root.map { [$0] } ?? windows
            for r in roots {
                if let hit = descendants(r).first(where: predicate) {
                    found = hit
                    return true
                }
            }
            return false
        }
        return found
    }

    func element(_ text: String, role wanted: String? = nil, exact: Bool = true, in root: AXUIElement? = nil, timeout: Double = 5) -> AXUIElement? {
        find({ el in
            if let wanted, role(el) != wanted { return false }
            return texts(el).contains { exact ? $0 == text : $0.contains(text) }
        }, in: root, timeout: timeout)
    }

    func button(_ text: String, exact: Bool = true, timeout: Double = 5) -> AXUIElement? {
        element(text, role: kAXButtonRole, exact: exact, timeout: timeout)
    }

    func hasText(_ text: String, timeout: Double = 5) -> Bool {
        element(text, exact: false, timeout: timeout) != nil
    }

    func value(of el: AXUIElement?) -> String { el.flatMap { str($0, kAXValueAttribute) } ?? "" }

    // MARK: Keyboard

    func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        activate()
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)!
            event.flags = flags
            event.postToPid(pid)
            pump(0.03)
        }
        pump(0.25)
    }

    func type(_ text: String) {
        for scalar in text.unicodeScalars {
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)!
                var chars = [UniChar](String(scalar).utf16)
                event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                event.postToPid(pid)
                pump(0.02)
            }
        }
        pump(0.2)
    }

    // MARK: Mouse (moves the real pointer; screen coordinates, top-left origin)

    /// Glides the pointer to `p` in small steps, like a real mouse, so tracking
    /// areas receive entered/moved events.
    func moveMouse(to p: CGPoint) {
        activate()
        // Approach quickly from straight above (from the video), the common
        // gesture that yields a single event inside the thin timeline.
        let start = CGPoint(x: p.x, y: p.y - 300)
        CGWarpMouseCursorPosition(start)
        let steps = 12
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let q = CGPoint(x: start.x + (p.x - start.x) * t, y: start.y + (p.y - start.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
            pump(0.02)
        }
        pump(0.4)
    }

    func click(at p: CGPoint) {
        moveMouse(to: p)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        pump(0.05)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        pump(0.6)
    }

    /// `count` quick clicks in one sequence (macOS numbers them 1, 2, 3…), e.g.
    /// 4 = two double-clicks in a row.
    func rapidClicks(at p: CGPoint, count: Int) {
        moveMouse(to: p)
        for n in 1...count {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event?.post(tap: .cghidEventTap)
                pump(0.04)
            }
            pump(0.05)
        }
    }

    // MARK: Menus

    func menu(_ path: [String]) -> Bool {
        guard let bar = attr(ax, kAXMenuBarAttribute) else { return false }
        var current = bar as! AXUIElement
        for (i, title) in path.enumerated() {
            let candidates = descendants(current, limit: 800).filter { el in
                let r = role(el)
                guard r == kAXMenuBarItemRole || r == kAXMenuItemRole else { return false }
                guard let t = str(el, kAXTitleAttribute) else { return false }
                return t == title || t.hasPrefix(title + "\t")
            }
            guard let item = candidates.first else { return false }
            press(item)
            pump(0.2)
            if i == path.count - 1 { return true }
            current = item
        }
        return false
    }

    // MARK: Launch Services

    func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        var done = false
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, _ in done = true }
        waitFor(5) { done }
        pump(0.5)
    }

    // MARK: Screenshots

    var windowNumber: CGWindowID? {
        // The player window: the largest on-screen window of the app (panels and
        // closed sheets may still exist off screen).
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
        func area(_ w: [String: Any]) -> Double {
            let b = w[kCGWindowBounds as String] as? [String: Any]
            return (b?["Width"] as? Double ?? 0) * (b?["Height"] as? Double ?? 0)
        }
        let player = mine.max { area($0) < area($1) }
        return (player?[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
    }

    func screenshot(_ url: URL) -> NSBitmapImageRep? {
        guard let id = windowNumber else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(id), url.path]
        try? p.run()
        p.waitUntilExit()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    func quit() {
        key(12, .maskCommand)  // ⌘Q
        waitFor(8) { !process.isRunning }
    }
}

/// Fraction of near-white pixels in a rectangle (screen points relative to the window).
func whiteFraction(_ image: NSBitmapImageRep, region: CGRect, windowFrame: CGRect) -> Double {
    let scale = Double(image.pixelsWide) / windowFrame.width
    let x0 = Int((region.minX - windowFrame.minX) * scale), x1 = Int((region.maxX - windowFrame.minX) * scale)
    let y0 = Int((region.minY - windowFrame.minY) * scale), y1 = Int((region.maxY - windowFrame.minY) * scale)
    var white = 0, total = 0
    for y in stride(from: max(0, y0), to: min(image.pixelsHigh, y1), by: 2) {
        for x in stride(from: max(0, x0), to: min(image.pixelsWide, x1), by: 2) {
            guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            total += 1
            if c.redComponent > 0.85, c.greenComponent > 0.85, c.blueComponent > 0.85 { white += 1 }
        }
    }
    return total == 0 ? 0 : Double(white) / Double(total)
}

// MARK: - Scenario

let args = CommandLine.arguments
guard args.count >= 4 else {
    log("usage: E2EDriver <app> <fixtures dir> <data dir>")
    exit(2)
}
let appURL = URL(fileURLWithPath: args[1])
let fixtures = URL(fileURLWithPath: args[2])
let dataDir = URL(fileURLWithPath: args[3])
let video = fixtures.appendingPathComponent("E2E Clip.mp4")
let subtitle = fixtures.appendingPathComponent("E2E Clip.srt")
let second = fixtures.appendingPathComponent("Second Clip.mp4")
let broken = fixtures.appendingPathComponent("Broken.mp4")
let exportURL = fixtures.appendingPathComponent("E2E Clip.synced.srt")
let logURL = dataDir.appendingPathComponent("app.log")
let shots = dataDir.appendingPathComponent("screens", isDirectory: true)
try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
try? FileManager.default.removeItem(at: exportURL)

guard AXIsProcessTrusted() else {
    log("Accessibility permission is required for the terminal running this driver.")
    exit(2)
}

/// Elapsed time from the label left of the timeline (the left-most clock label in the control bar).
// Cue times (file timing, seconds) written by run-e2e.sh; the audio speaks each line 1.2 s later.
let cueTimes: [(Double, Double)] = ((try? String(contentsOf: fixtures.appendingPathComponent("cues.txt"), encoding: .utf8)) ?? "")
    .split(separator: "\n").compactMap { line in
        let p = line.split(separator: " ").compactMap { Double($0) }
        return p.count == 2 ? (max(0, p[0]), p[1]) : nil
    }

func covered(_ t: Double, shift: Double) -> Bool { cueTimes.contains { $0.0 + shift <= t && t < $0.1 + shift } }

/// A line long enough to test, whose “before” moment is not covered by any line after a +1.2 s shift.
let testCue: Int = cueTimes.indices.first { i in
    let (a, b) = cueTimes[i]
    return a >= 2 && b - a >= 1.0 && !covered(a + 0.4, shift: 1.2) && covered(a + 1.6, shift: 1.2)
} ?? 1

func srtTime(_ t: Double) -> String {
    let ms = Int((max(0, t) * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

func elapsed(_ app: AppUnderTest) -> Double {
    guard let window = app.mainWindow, let slider = app.element("Playback position", role: kAXSliderRole, in: window, timeout: 1),
          let sf = frame(slider) else { return -1 }
    let clock = try! NSRegularExpression(pattern: #"^\d+:\d\d(:\d\d)?$"#)
    let labels = descendants(window).filter { el in
        guard role(el) == kAXStaticTextRole || role(el) == kAXButtonRole, let v = str(el, kAXValueAttribute) ?? str(el, kAXTitleAttribute),
            let f = frame(el)
        else { return false }
        return clock.firstMatch(in: v, range: NSRange(location: 0, length: (v as NSString).length)) != nil
            && abs(f.midY - sf.midY) < 12 && f.maxX <= sf.minX + 4
    }
    guard let label = labels.first, let value = str(label, kAXValueAttribute) ?? str(label, kAXTitleAttribute) else { return -1 }
    return value.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
}

/// Value of a labelled offset readout (“Subtitle offset” / “Audio delay”) in the visible panel.
func readout(_ app: AppUnderTest, _ label: String) -> String {
    guard let el = app.find({ role($0) == kAXStaticTextRole && str($0, kAXDescriptionAttribute) == label }, timeout: 2) else { return "<missing>" }
    return str(el, kAXValueAttribute) ?? "<no value>"
}

func readoutIs(_ app: AppUnderTest, _ label: String, _ expected: String, timeout: Double = 3) -> Bool {
    waitFor(timeout) { readout(app, label) == expected }
}

func seek(_ app: AppUnderTest, to seconds: Double) {
    guard let slider = app.element("Playback position", role: kAXSliderRole) else {
        check(false, "timeline slider found")
        return
    }
    _ = setValue(slider, NSNumber(value: seconds))
    pump(0.8)
}

func subtitleVisible(_ app: AppUnderTest, _ name: String) -> Bool? {
    guard let window = app.mainWindow, let wf = frame(window),
          let videoEl = app.element("Video", role: kAXImageRole), let vf = frame(videoEl),
          let image = app.screenshot(shots.appendingPathComponent("\(name).png")) else { return nil }
    // Subtitles are drawn in the lower part of the video surface.
    let region = CGRect(x: vf.minX, y: vf.minY + vf.height * 0.72, width: vf.width, height: vf.height * 0.28)
    return whiteFraction(image, region: region, windowFrame: wf) > 0.002
}

log("RVLC end-to-end test")
log("App: \(appURL.path)")

// 1. Launch without a file: empty state.
log("\n1. Launch and empty state")
var app = try AppUnderTest(appURL: appURL, file: nil, dataDir: dataDir, reset: true, logURL: logURL)
diagnostics = { app.focusReport() }
app.activate()
check(waitFor(10) { app.mainWindow != nil }, "main window appears")
check(app.button("Open File…") != nil, "empty state offers Open File…")
check(app.hasText("Play anything. Fix everything."), "tagline shown")
check(app.button("Play", timeout: 1).map { (attr($0, kAXEnabledAttribute) as? Bool) == false } ?? false,
      "Play is disabled with nothing to play")

// 2. Open a video via Launch Services (Finder “Open With”).
log("\n2. Open video and play")
app.open(video)
check(waitFor(10) { app.mainWindow.flatMap { str($0, kAXTitleAttribute) } == "E2E Clip.mp4" }, "window title shows the file")
check(waitFor(6) { elapsed(app) >= 2 }, "playback advances", "elapsed \(elapsed(app))")
check(app.element("Open File…", timeout: 0.5) == nil, "empty state hidden while playing")

// 3. Play/Pause button and Space key.
log("\n3. Transport controls")
if let pause = app.button("Pause") {
    press(pause)
    pump(0.6)
    let t0 = elapsed(app)
    pump(1.5)
    check(elapsed(app) == t0, "Pause button stops playback", "\(t0) → \(elapsed(app))")
    check(app.button("Play", timeout: 2) != nil, "button switches to Play")
    app.key(49)  // Space
    let t1 = elapsed(app)
    check(waitFor(4) { elapsed(app) > t1 }, "Space resumes playback")
} else {
    check(false, "Pause button present while playing")
}
let beforeSeek = elapsed(app)
app.key(124)  // →
check(waitFor(3) { elapsed(app) >= beforeSeek + 4 }, "→ seeks forward 5 s", "\(beforeSeek) → \(elapsed(app))")
let beforeBack = elapsed(app)
app.key(123)  // ←
check(waitFor(3) { elapsed(app) <= beforeBack - 3 }, "← seeks back", "\(beforeBack) → \(elapsed(app))")
seek(app, to: 20)
check(waitFor(3) { abs(elapsed(app) - 20) <= 1 }, "timeline slider (accessibility) seeks to 0:20", "\(elapsed(app))")

// 3b. Timeline hover label and going to a specific time.
log("\n3b. Timeline hover and Go to Time")
app.key(49)  // pause so positions are exact
pump(0.4)
if let slider = app.element("Playback position", role: kAXSliderRole), let sf = frame(slider) {
    let point = CGPoint(x: sf.minX + sf.width * 0.6, y: sf.midY)
    app.moveMouse(to: point)
    let hover = app.find({ texts($0).contains("Time under pointer") }, timeout: 3)
    let hoverText = hover.flatMap { str($0, kAXValueAttribute) }?.trimmingCharacters(in: .whitespaces) ?? ""
    let hf = hover.flatMap(frame) ?? .zero
    if hoverText.isEmpty {
        _ = app.screenshot(shots.appendingPathComponent("hover-fail.png"))
        let all = app.windows.flatMap { descendants($0) }.filter { texts($0).contains { $0.contains("pointer") } }
        log("    debug: hover candidates \(all.map { texts($0) }), mouse \(CGEvent(source: nil)?.location ?? .zero), slider \(sf)")
    }
    check(!hoverText.isEmpty, "hovering the timeline shows the time under the pointer", hoverText)
    check(!hf.intersects(sf.insetBy(dx: 0, dy: 2)), "hover time does not overlap the timeline or pointer", "label \(hf), bar \(sf)")
    check(hf.maxY <= sf.minY + 1, "hover time sits above the timeline", "label \(hf), bar \(sf)")
    let expected = hoverText.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
    app.click(at: point)
    check(waitFor(3) { abs(elapsed(app) - expected) < 1 }, "clicking goes to the time the label showed", "label \(hoverText), now \(elapsed(app))")
    app.moveMouse(to: CGPoint(x: sf.midX, y: sf.minY - 200))  // move away so the label hides
} else {
    check(false, "timeline slider found")
}
app.key(38, .maskCommand)  // ⌘J Go to Time
if let field = app.element("Time to go to", role: kAXTextFieldRole, timeout: 3) {
    _ = setValue(field, "99:00" as CFString)
    app.key(36)  // Return
    check(app.hasText("The video is only 0:30 long.", timeout: 2), "Go to Time rejects a time beyond the end")
    _ = setValue(field, "0:12" as CFString)
    app.key(36)
    check(waitFor(3) { abs(elapsed(app) - 12) < 0.6 }, "Go to Time jumps to 0:12", "now \(elapsed(app))")
    check(app.element("Time to go to", role: kAXTextFieldRole, timeout: 0.5) == nil, "sheet closes after jumping")
} else {
    check(false, "⌘J opens Go to Time")
}
app.key(49)  // resume playback

// 4. Volume and mute through keys, feedback through the on-screen message.
log("\n4. Volume and mute")
app.key(125)  // ↓
check(app.hasText("Volume 75%", timeout: 3), "↓ lowers volume to 75% with on-screen feedback")
app.key(46)  // M
check(app.hasText("Muted", timeout: 3), "M mutes")
check(app.element("Unmute", role: kAXButtonRole, timeout: 2) != nil, "mute button offers Unmute")
app.key(46)
check(app.hasText("Volume 75%", timeout: 3), "M unmutes")

// 5. Subtitles via Launch Services, Subtitle Studio and offset direction on screen.
log("\n5. Subtitle import and offset")
app.key(49)  // pause for deterministic frames
pump(0.5)
app.open(subtitle)
check(app.hasText("Subtitles: E2E Clip.srt", timeout: 5), "subtitle file accepted while playing")
app.key(20, .maskCommand)  // ⌘3 Subtitle Studio
check(app.hasText("Subtitle Studio", timeout: 3), "⌘3 opens Subtitle Studio")
check(app.element("E2E Clip.srt", role: kAXStaticTextRole, timeout: 3) != nil, "Studio shows the imported file")
let (cueStart, cueEnd) = cueTimes.isEmpty ? (2.8, 4.0) : cueTimes[testCue]
let before = cueStart + 0.4, after = cueStart + 1.6
seek(app, to: before)
pump(0.6)
let visibleAtStart = subtitleVisible(app, "sub-0ms-before")
check(visibleAtStart == true, "subtitle drawn at \(before) s with no offset", "\(String(describing: visibleAtStart))")
app.key(7); app.key(7)  // X ×2
check(app.hasText("Subtitle offset +0.200 s", timeout: 3), "X ×2 → +0.200 s")
app.key(6, .maskShift)  // ⇧Z reset
check(app.hasText("+0.000 s", timeout: 3), "⇧Z resets the offset")
if let field = app.element("Subtitle offset in milliseconds", role: kAXTextFieldRole) {
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    _ = setValue(field, "1200" as CFString)
    app.key(36)  // Return commits
    check(app.hasText("Subtitle offset +1.200 s", timeout: 3), "exact entry 1200 ms applies +1.200 s")
} else {
    check(false, "exact offset field present")
}
seek(app, to: before)
pump(0.6)
check(subtitleVisible(app, "sub-1200ms-before") == false, "positive offset: line no longer shown at \(before) s")
seek(app, to: after)
pump(0.6)
check(subtitleVisible(app, "sub-1200ms-after") == true, "positive offset: line shown later, at \(after) s")

// 6. Manual reference-point sync.
log("\n6. Sync line to now")
app.key(6, .maskShift)  // reset
check(readoutIs(app, "Subtitle offset", "+0.000 s"), "⇧Z works again after typing an exact value", readout(app, "Subtitle offset"))
if let table = app.element("Subtitle lines", role: kAXTableRole) {
    let rows = children(table).filter { role($0) == kAXRowRole }
    check(rows.count == cueTimes.count, "line list shows all lines", "\(rows.count) rows, \(cueTimes.count) cues")
    if rows.count > testCue {
        AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [rows[testCue]] as CFArray)
        pump(0.3)
    }
} else {
    check(false, "line list present")
}
seek(app, to: cueStart + 1.2)  // the selected line is actually heard 1.2 s after its subtitle time
if let sync = app.button("Sync Line to Now") {
    press(sync)
    // Playback positions are frame-accurate (40 ms at 25 fps), so allow one frame.
    // The suggestion card's title starts with “Shift subtitles”; the on-screen message merely contains it.
    let card = app.find({ el in texts(el).contains { $0.hasPrefix("Shift subtitles ") } }, timeout: 3)
    let suggestion = card.flatMap { texts($0).first { $0.hasPrefix("Shift subtitles ") } } ?? ""
    let amount = Double(suggestion.dropFirst("Shift subtitles ".count).prefix { $0 != " " }) ?? -1
    check(abs(amount - 1.2) <= 0.041 && suggestion.contains("later"), "suggestion: shift ≈1.2 s later", suggestion)
    check(readoutIs(app, "Subtitle offset", "+0.000 s", timeout: 1), "suggestion is not applied until confirmed", readout(app, "Subtitle offset"))
    if let apply = app.button("Apply") { press(apply) }
    let applied = readout(app, "Subtitle offset")
    check(waitFor(3) { abs((Double(readout(app, "Subtitle offset").dropFirst().prefix { $0 != " " }) ?? 0) - 1.2) <= 0.041 },
          "Apply sets ≈+1.200 s", applied)
} else {
    check(false, "Sync Line to Now button present")
}

// 7. Automatic sync from audio (suggest, then discard).
log("\n7. Automatic sync")
app.key(6, .maskShift)
if let analyze = app.button("Analyze Audio") {
    press(analyze)
    let found = app.element("Shift subtitles 1.", exact: false, timeout: 40)
    check(found != nil, "audio analysis suggests ~1.2 s later", texts(found ?? app.ax).joined(separator: " | "))
    check(app.hasText("confidence", timeout: 1), "suggestion shows a confidence level")
    if let discard = app.button("Discard") { press(discard) }
    check(readoutIs(app, "Subtitle offset", "+0.000 s"), "Discard leaves timing unchanged", readout(app, "Subtitle offset"))
} else {
    check(false, "Analyze Audio button present")
}

// 8. Export through the save panel.
log("\n8. Export")
app.key(7)  // +100 ms so the export differs from the source
check(readoutIs(app, "Subtitle offset", "+0.100 s"), "X adds 100 ms before export", readout(app, "Subtitle offset"))
if let export = app.button("Export…") {
    press(export)
    let nameField = app.find({ role($0) == kAXTextFieldRole && (str($0, kAXValueAttribute) ?? "").hasSuffix(".srt") }, timeout: 5)
    check(nameField != nil, "save panel opens with a suggested .srt name", app.value(of: nameField))
    if let save = app.button("Save", timeout: 3) {
        press(save)
        check(app.hasText("Subtitles exported", timeout: 5), "export confirmation shown")
        if let ok = app.button("OK", timeout: 3) { press(ok) }
    }
    let exported = (try? String(contentsOf: exportURL, encoding: .utf8)) ?? ""
    let expected = "\(srtTime(cueStart + 0.1)) --> \(srtTime(cueEnd + 0.1))"
    check(exported.contains(expected), "exported file has +100 ms timing", "expected \(expected)")
    let original = (try? String(contentsOf: subtitle, encoding: .utf8)) ?? ""
    check(original.contains("\(srtTime(cueStart)) --> \(srtTime(cueEnd))"), "original subtitle file unchanged")
} else {
    check(false, "Export… button present")
}

// 9. Audio Sync Lab is independent of subtitle timing.
log("\n9. Audio Sync Lab")
app.key(21, .maskCommand)  // ⌘4
check(app.hasText("Audio Sync Lab", timeout: 3), "⌘4 opens Audio Sync Lab")
if let plus = app.button("+250") {
    press(plus)
    check(app.hasText("Audio delay +0.250 s", timeout: 3), "+250 button sets audio delay")
}
app.key(9)  // V
check(app.hasText("Audio delay +0.350 s", timeout: 3), "V adds the audio step")
check(readoutIs(app, "Audio delay", "+0.350 s"), "audio readout shows +0.350 s", readout(app, "Audio delay"))
app.key(20, .maskCommand)
check(readoutIs(app, "Subtitle offset", "+0.100 s"), "subtitle offset untouched by audio changes", readout(app, "Subtitle offset"))

// 10. Shortcuts never fire while typing.
log("\n10. Typing safety")
app.key(19, .maskCommand)  // ⌘2 Library
if let search = app.element("Search library", timeout: 3) {
    AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    pump(0.3)
    app.type("zx m")
    check(app.value(of: search).contains("zx m"), "typed text reaches the search field", app.value(of: search))
    check(!app.hasText("Muted", timeout: 0.5), "M typed in a field does not mute")
    app.key(53)  // Esc
} else {
    check(false, "library search field present")
}
app.key(20, .maskCommand)
check(readoutIs(app, "Subtitle offset", "+0.100 s"), "Z/X typed in a field do not change the subtitle offset", readout(app, "Subtitle offset"))
app.key(19, .maskCommand)
check(app.element("E2E Clip", role: kAXStaticTextRole, timeout: 3) != nil || app.hasText("E2E Clip", timeout: 1), "library lists the played file")

// 11. Playlist navigation via a second file.
log("\n11. Playlist")
app.open(second)
check(waitFor(8) { app.mainWindow.flatMap { str($0, kAXTitleAttribute) } == "Second Clip.mp4" }, "second file opens")
app.key(35)  // P → previous item (position < 3 s)
check(waitFor(8) { app.mainWindow.flatMap { str($0, kAXTitleAttribute) } == "E2E Clip.mp4" }, "P returns to the previous item")
app.key(45)  // N → next
check(waitFor(8) { app.mainWindow.flatMap { str($0, kAXTitleAttribute) } == "Second Clip.mp4" }, "N goes to the next item")

// 12. Full screen.
log("\n12. Full screen")
if let window = app.mainWindow {
    // Full screen is instant (no Spaces animation): the window covers the whole screen.
    let screen = NSScreen.screens.first?.frame.size ?? .zero
    let before = frame(window) ?? .zero
    func coversScreen() -> Bool { (frame(window)?.size).map { $0.width >= screen.width && $0.height >= screen.height } ?? false }
    app.key(3)  // F
    check(waitFor(3) { coversScreen() }, "F enters full screen", "\(frame(window) ?? .zero) vs screen \(screen)")
    pump(0.3)
    app.key(53)  // Esc
    check(waitFor(3) { frame(window) == before }, "Esc exits full screen and restores the window", "\(frame(window) ?? .zero) vs \(before)")
    // Two quick double-clicks on the picture: zoom in and straight back out.
    let video = CGPoint(x: before.midX - 150, y: before.minY + before.height * 0.4)
    let wasPlaying = app.button("Pause", timeout: 0.5) != nil
    app.rapidClicks(at: video, count: 4)
    pump(1.0)
    check(frame(window) == before, "two quick double-clicks zoom in and back out", "\(frame(window) ?? .zero) vs \(before)")
    check((app.button("Pause", timeout: 0.5) != nil) == wasPlaying, "double-clicks do not play or pause")
    pump(0.5)
}

// 13. Small window: controls remain usable and never overlap.
log("\n13. Responsive layout")
if let window = app.mainWindow {
    app.key(1, [.maskCommand, .maskControl])  // ⌃⌘S hides the sidebar so the window can get narrow
    pump(0.6)
    var size = CGSize(width: 520, height: 360)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    pump(0.8)
    let wf = frame(window) ?? .zero
    let bar = descendants(window, limit: 1500).first { texts($0).contains("Playback controls") }
    check(bar != nil, "control bar is exposed to accessibility as a group")
    let buttons = bar.map { descendants($0).filter { role($0) == kAXButtonRole } } ?? []
    let frames = buttons.compactMap(frame).filter { $0.width > 1 && $0.height > 1 }
    var overlap = false
    for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] where a.insetBy(dx: 1, dy: 1).intersects(b) { overlap = true } }
    check(wf.width <= 540, "window shrinks to 520 pt", "\(wf)")
    check(!overlap, "control buttons do not overlap at 520 pt")
    check(frames.allSatisfy { $0.maxX <= wf.maxX + 1 }, "control buttons stay inside the window")
    check(app.button("Pause", timeout: 1) != nil || app.button("Play", timeout: 1) != nil, "play/pause stays visible")
    var big = CGSize(width: 1100, height: 680)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &big)!)
    app.key(1, [.maskCommand, .maskControl])  // show the sidebar again
    pump(0.5)
    check(app.hasText("Library", timeout: 2), "⌃⌘S shows the sidebar again")
}

// 14. Error state for an unplayable file.
log("\n14. Error handling")
app.open(broken)
check(app.hasText("This file can’t be played", timeout: 8), "broken file shows an error")
if let dismiss = app.button("Dismiss") {
    press(dismiss)
    check(app.button("Open File…", timeout: 4) != nil, "Dismiss returns to the empty state")
}

// 15. Settings: theme is applied and persisted.
log("\n15. Settings")
app.key(43, .maskCommand)  // ⌘,
if let settings = app.find({ str($0, kAXTitleAttribute) == "RVLC Settings" && role($0) == kAXWindowRole }, in: app.ax, timeout: 4) {
    if let dark = app.find({ role($0) == kAXRadioButtonRole && texts($0).contains("Dark") }, in: settings, timeout: 3) {
        press(dark)
        pump(0.5)
    }
    let theme = UserDefaults(suiteName: "org.rvlc.player.isolated")?.string(forKey: "theme")
    check(theme == "dark", "Dark theme selected and persisted", theme ?? "nil")
    if let light = app.find({ role($0) == kAXRadioButtonRole && texts($0).contains("System") }, in: settings, timeout: 3) {
        press(light)
    }
    app.key(13, .maskCommand)  // ⌘W
} else {
    check(false, "⌘, opens Settings")
}

// 16. Resume after relaunch.
log("\n16. Quit and resume")
app.open(video)
check(waitFor(8) { app.mainWindow.flatMap { str($0, kAXTitleAttribute) } == "E2E Clip.mp4" }, "video reopened")
seek(app, to: 12)
pump(1.0)
app.quit()
check(!app.process.isRunning, "⌘Q quits cleanly")
let library = (try? String(contentsOf: dataDir.appendingPathComponent("library.json"), encoding: .utf8)) ?? ""
check(library.contains("\"position\""), "position saved to the library on quit")
check(library.contains("\"audioDelayMs\" : 350"), "per-file audio delay saved", "")
app = try AppUnderTest(appURL: appURL, file: video, dataDir: dataDir, reset: false, logURL: logURL)
diagnostics = { app.focusReport() }
app.activate()
check(app.hasText("Resumed at 0:1", timeout: 10), "relaunch resumes where playback stopped")
check(app.hasText("Subtitles: E2E Clip.srt", timeout: 5), "remembered subtitle reloaded")
app.key(21, .maskCommand)
check(readoutIs(app, "Audio delay", "+0.350 s", timeout: 5), "remembered audio delay restored", readout(app, "Audio delay"))
app.quit()
check(!app.process.isRunning, "second session quits cleanly")

// Log scan.
let appLog = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
let suspicious = appLog.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains("fatal") || $0.contains("Unable to simultaneously satisfy constraints") || $0.contains("Thread ") && $0.contains("crashed") }
check(suspicious.isEmpty, "no crashes or constraint conflicts in the app log", suspicious.prefix(3).joined(separator: " / "))

log("\n\(passes) checks passed, \(failures.count) failed")
for f in failures { log("  FAILED: \(f)") }
exit(failures.isEmpty ? 0 : 1)
