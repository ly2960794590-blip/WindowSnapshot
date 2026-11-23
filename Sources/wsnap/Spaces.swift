import AppKit
import WSnapCore

struct SysTile {
    let wid: Int
    let rect: Rect
}

struct SysSpace {
    let id: Int
    /// True for a regular desktop, false for a full-screen / Split View space.
    let isDesktop: Bool
    let tiles: [SysTile]
}

struct SysDisplay {
    let uuid: String
    let current: Int
    let spaces: [SysSpace]

    var desktops: [SysSpace] { spaces.filter(\.isDesktop) }
}

struct SysWindow {
    let wid: Int
    let pid: pid_t
    let owner: String
    let title: String
    let bundle: String
    let appPath: String
    let bounds: Rect
    let spaces: [Int]
}

/// Reads the Mission Control layout. With the private WindowServer calls available this is the
/// real list of desktops and full-screen spaces; without them it degrades to "one desktop per
/// display, containing whatever is visible right now".
enum Spaces {
    static var available: Bool { PrivateAPI.canReadSpaces && PrivateAPI.canMapWindowsToSpaces && real() != nil }

    private static func num(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    private static func rect(_ v: Any?) -> Rect {
        let d = v as? [String: Any] ?? [:]
        return Rect(x: num(d["X"]), y: num(d["Y"]), w: num(d["Width"]), h: num(d["Height"]))
    }

    private static func real() -> [SysDisplay]? {
        guard let raw = PrivateAPI.managedDisplaySpaces(), !raw.isEmpty else { return nil }
        let mainUUID = Screens.main?.uuid ?? ""
        var out: [SysDisplay] = []
        for d in raw {
            guard let rawSpaces = d["Spaces"] as? [[String: Any]] else { return nil }
            var uuid = d["Display Identifier"] as? String ?? ""
            // With "Displays have separate Spaces" off there is a single entry called "Main".
            if uuid == "Main" || uuid.isEmpty { uuid = mainUUID }
            let spaces = rawSpaces.map { s -> SysSpace in
                let tileList = (s["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]] ?? []
                let tiles = tileList.map { SysTile(wid: num($0["TileWindowID"]), rect: rect($0["TileRect"])) }
                return SysSpace(id: num(s["ManagedSpaceID"]), isDesktop: num(s["type"]) == 0, tiles: tiles)
            }
            let current = num((d["Current Space"] as? [String: Any])?["ManagedSpaceID"])
            out.append(SysDisplay(uuid: uuid, current: current, spaces: spaces))
        }
        return out
    }

    /// Fallback ids for the single pseudo-desktop of each display.
    private static func pseudoSpaceID(_ index: Int) -> Int { -1000 - index }

    static func displays() -> [SysDisplay] {
        if PrivateAPI.canMapWindowsToSpaces, let r = real() { return r }
        return Screens.all().enumerated().map { i, s in
            SysDisplay(uuid: s.uuid, current: pseudoSpaceID(i),
                       spaces: [SysSpace(id: pseudoSpaceID(i), isDesktop: true, tiles: [])])
        }
    }

    static func display(_ uuid: String) -> SysDisplay? { displays().first { $0.uuid == uuid } }

    static func fullscreenSpaceIDs() -> Set<Int> {
        Set(displays().flatMap { $0.spaces.filter { !$0.isDesktop }.map(\.id) })
    }

    /// Normal application windows (layer 0) with the Spaces they are on.
    static func windows() -> [SysWindow] {
        let useReal = available
        let options: CGWindowListOption = useReal ? [.optionAll, .excludeDesktopElements]
                                                  : [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let screens = Screens.all()
        var out: [SysWindow] = []
        for w in list {
            guard num(w[kCGWindowLayer as String]) == 0 else { continue }
            if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 { continue }
            let wid = num(w[kCGWindowNumber as String])
            let pid = pid_t(num(w[kCGWindowOwnerPID as String]))
            let bounds = rect(w[kCGWindowBounds as String])
            let app = NSRunningApplication(processIdentifier: pid)
            let spaces: [Int]
            if useReal {
                spaces = PrivateAPI.spaces(forWindow: CGWindowID(wid)) ?? []
            } else {
                let i = screens.firstIndex { $0.frame.contains(x: bounds.centerX, y: bounds.centerY) } ?? 0
                spaces = [pseudoSpaceID(i)]
            }
            out.append(SysWindow(wid: wid, pid: pid,
                                 owner: w[kCGWindowOwnerName as String] as? String ?? "",
                                 title: w[kCGWindowName as String] as? String ?? "",
                                 bundle: app?.bundleIdentifier ?? "",
                                 appPath: app?.bundleURL?.path ?? "",
                                 bounds: bounds, spaces: spaces))
        }
        return out
    }

    static var displaysHaveSeparateSpaces: Bool {
        // The key is absent by default, which means "separate Spaces" is on.
        !(UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false)
    }

    // MARK: Switching

    /// Moves `displayUUID` to its n-th regular desktop using the user's own "Move left/right a
    /// space" shortcuts, checking after every step that the switch really happened.
    static func goToDesktop(_ n: Int, onDisplay displayUUID: String) -> Bool {
        guard available else { return true }  // nothing to switch between
        let left = Keyboard.moveLeftASpace, right = Keyboard.moveRightASpace
        guard left.enabled, right.enabled else { return false }
        var last = Int.min
        var stuck = 0
        for _ in 0..<40 {
            Screens.moveMouse(toDisplay: displayUUID)
            guard let d = display(displayUUID), n >= 1, n <= d.desktops.count else { return false }
            let target = d.desktops[n - 1].id
            if d.current == target {
                Thread.sleep(forTimeInterval: 0.4)
                return true
            }
            if d.current == last {
                stuck += 1
                if stuck >= 4 { return false }
            } else {
                last = d.current
                stuck = 0
            }
            let order = d.spaces.map(\.id)
            guard let ti = order.firstIndex(of: target), let ci = order.firstIndex(of: d.current) else { return false }
            Keyboard.press(ti > ci ? right : left)
            Thread.sleep(forTimeInterval: 1.0)
        }
        return false
    }
}
