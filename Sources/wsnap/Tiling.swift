import AppKit
import ApplicationServices
import WSnapCore

/// Builds Split Views and positions full-screen spaces, which macOS offers no API for.
///
/// It drives the same controls a person would use:
///   1. "Window → Full Screen Tile → Left of Screen" on the first window. The menu item is found
///      by its identifier (`_tileLeft:`), not by its translated title.
///   2. macOS then shows the remaining windows as thumbnails to pick the other half from; the
///      thumbnail of the wanted window is clicked.
///
/// Two things follow from how macOS behaves here:
///   - A space made this way is inserted right after the desktop it was made from, whereas a
///     plain "enter full screen" always lands after every other space.
///   - When one half of a Split View closes, the other half becomes an ordinary full-screen
///     window and the space stays where it is.
/// So a single full-screen window can be put right after a chosen desktop by pairing it with a
/// throw-away helper window and closing the helper.
enum Tiling {
    static let tileLeftIdentifier = "_tileLeft:"

    static var supported: Bool { Spaces.available && PrivateAPI.canGetAXWindowID }

    static func bounds(ofWindow wid: Int) -> Rect? {
        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(wid)) as? [[String: Any]] ?? []
        guard let d = list.first?[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func n(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        return Rect(x: n("X"), y: n("Y"), w: n("Width"), h: n("Height"))
    }

    static func windowIDs(ofPID pid: pid_t) -> [Int] {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
                && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
        }.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue }
    }

    static func click(x: Int, y: Int) {
        let p = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .hidSystemState)
        CGWarpMouseCursorPosition(p)
        Thread.sleep(forTimeInterval: 0.2)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.12)
        }
    }

    static func pressEscape() {
        Keyboard.press(Hotkey(keyCode: 53, modifiers: 0, enabled: true))
    }

    private static func space(containing wid: Int) -> SysSpace? {
        Spaces.displays().flatMap(\.spaces).first { !$0.isDesktop && $0.tiles.contains { $0.wid == wid } }
    }

    /// Step 1. Returns the window id once the window sits in the left half of a new space.
    static func tileLeft(_ element: AXUIElement, pid: pid_t) -> Int? {
        guard supported, let wid = PrivateAPI.windowID(of: element).map(Int.init) else {
            debug("tileLeft: tiling not supported or window id unknown")
            return nil
        }
        guard AX.menuItem(pid: pid, identifier: tileLeftIdentifier) != nil else {
            debug("tileLeft: app has no \(tileLeftIdentifier) menu item")
            return nil
        }
        // The menu item is only enabled while the window is the app's main window and the app
        // is frontmost, which can take a moment after a window was just opened.
        var pressed = false
        for attempt in 0..<10 {
            NSRunningApplication(processIdentifier: pid)?.activate()
            AX.raise(element)
            AX.set(element, kAXMainAttribute, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 0.6)
            guard let item = AX.menuItem(pid: pid, identifier: tileLeftIdentifier) else { break }
            let enabled = (AX.value(item, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? false
            debug("tileLeft: window \(wid), attempt \(attempt), menu item enabled=\(enabled)")
            if enabled {
                pressed = AX.press(item)
                break
            }
        }
        guard pressed else {
            debug("tileLeft: menu item stayed disabled")
            return nil
        }
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.5)
            if space(containing: wid) != nil {
                Thread.sleep(forTimeInterval: 1.2)  // let the thumbnails settle
                return wid
            }
        }
        debug("tileLeft: window \(wid) never appeared in a tiled space")
        return nil
    }

    /// Step 2. Clicks the thumbnail of `partner`; true once both windows share the space.
    static func choosePartner(_ partner: Int, for primary: Int) -> Bool {
        for _ in 0..<3 {
            guard let b = bounds(ofWindow: partner) else {
                debug("choosePartner: window \(partner) is gone")
                return false
            }
            debug("choosePartner: clicking thumbnail of \(partner) at \(b)")
            click(x: b.centerX, y: b.centerY)
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.5)
                if let s = space(containing: primary), s.tiles.contains(where: { $0.wid == partner }) {
                    Thread.sleep(forTimeInterval: 1.0)
                    return true
                }
            }
        }
        return false
    }

    /// Backs out of a half-finished tiling so the window returns to its desktop.
    static func cancel(primary: Int) {
        pressEscape()
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.5)
            if space(containing: primary) == nil { return }
        }
    }

    /// Waits until `wid` is alone in its space (after the other half was closed).
    static func waitUntilAlone(_ wid: Int) -> Bool {
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 0.5)
            if let s = space(containing: wid), s.tiles.filter({ $0.wid != 0 }).count == 1 { return true }
        }
        return false
    }
}

/// A plain, empty window owned by a second copy of this program. It exists only to be the other
/// half of a Split View for a moment (see `Tiling`).
final class HelperWindow {
    private let process: Process
    let wid: Int

    private init(process: Process, wid: Int) {
        self.process = process
        self.wid = wid
    }

    static func spawn(onScreen frame: Rect) -> HelperWindow? {
        guard let exe = Bundle.main.executablePath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["_helper-window", String(frame.x + frame.w / 2 - 300), String(frame.y + frame.h / 2 - 200)]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if let wid = Tiling.windowIDs(ofPID: p.processIdentifier).first {
                Thread.sleep(forTimeInterval: 0.5)
                return HelperWindow(process: p, wid: wid)
            }
        }
        p.terminate()
        return nil
    }

    func close() {
        if process.isRunning { process.terminate() }
    }

    /// Entry point of the helper process: show one resizable window and wait to be terminated.
    static func runAsHelper(x: Int, y: Int) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        // AppKit's origin is the bottom-left of the main screen; ours is the top-left.
        let rect = NSRect(x: CGFloat(x), y: screenHeight - CGFloat(y) - 400, width: 600, height: 400)
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        w.title = "wsnap"
        w.collectionBehavior = [.fullScreenPrimary, .fullScreenAllowsTiling]
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        // Never outlive the parent by long if it crashes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
        app.run()
        exit(0)
    }
}
