import AppKit
import ApplicationServices
import WSnapCore

private let S = ScriptedWindowParser.separator

/// A freshly opened browser window: its scripting id and, when found, its accessibility element.
struct OpenedWindow {
    let scriptedID: Int
    let element: AXUIElement?
}

private func scriptedIDs(app: String) -> [Int] {
    let r = Script.run("tell application \"\(app)\" to get id of every window")
    return r.out.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
}

private func waitForNewWindow(app: String, before: Set<Int>) -> Int? {
    for _ in 0..<30 {
        Thread.sleep(forTimeInterval: 0.5)
        if let id = scriptedIDs(app: app).first(where: { !before.contains($0) }) {
            Thread.sleep(forTimeInterval: 1.0)
            return id
        }
    }
    return nil
}

private func newAXWindow(bundle: String, before: Set<Int>) -> AXUIElement? {
    guard let pid = Apps.pid(bundle) else { return nil }
    return AX.windows(pid: pid).first { w in
        guard let wid = w.wid else { return false }
        return !before.contains(wid) && !w.title.isEmpty
    }?.element
}

private func axWindowIDs(bundle: String) -> Set<Int> {
    guard let pid = Apps.pid(bundle) else { return [] }
    return Set(AX.windows(pid: pid).compactMap(\.wid))
}

private func asBounds(_ r: Rect) -> String { "{\(r.x), \(r.y), \(r.x + r.w), \(r.y + r.h)}" }

// MARK: - Chrome

enum Chrome {
    static let bundle = "com.google.Chrome"
    static let appName = "Google Chrome"
    /// Part of every profile path shown on chrome://version.
    static let userDataMarker = "/Google/Chrome/"

    static var isRunning: Bool { Apps.running(bundle) != nil }

    static func windows() -> [ScriptedWindow] {
        guard isRunning else { return [] }
        let r = Script.run("""
        set S to "\(S)"
        set out to ""
        tell application "\(appName)"
          repeat with w in windows
            set b to bounds of w
            set out to out & "W" & S & (id of w) & S & (item 1 of b) & S & (item 2 of b) & S & (item 3 of b) & S & (item 4 of b) & S & ((mode of w) is "incognito") & S & (minimized of w) & S & (active tab index of w) & S & (title of w) & linefeed
            repeat with t in tabs of w
              set out to out & "T" & S & (URL of t) & S & (title of t) & linefeed
            end repeat
          end repeat
        end tell
        return out
        """)
        return r.ok ? ScriptedWindowParser.parse(r.out) : []
    }

    /// Profile names by window-server id, read from the accessibility titles of all windows.
    static func profileLabels() -> [Int: String] {
        guard let pid = Apps.pid(bundle) else { return [:] }
        var out: [Int: String] = [:]
        for w in AX.windows(pid: pid) {
            if let wid = w.wid, let label = TitleParsing.chromiumProfileLabel(axTitle: w.title, appName: appName) {
                out[wid] = label
            }
        }
        return out
    }

    // --- profile name -> profile directory

    private static func loadCache() -> [String: String] {
        guard let d = try? Data(contentsOf: Paths.chromeProfiles) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    private static func saveCache(_ c: [String: String]) {
        Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(c) { try? d.write(to: Paths.chromeProfiles) }
    }

    /// Chrome can only be told to open a window in a given profile by directory name
    /// ("Profile 3"), and macOS no longer lets other apps read Chrome's data folder to look it
    /// up. So we ask Chrome itself: open chrome://version in a tab of that window, read the
    /// "Profile Path" line through accessibility, close the tab. Done once per profile, then cached.
    static func profileDir(label: String, scriptedID: Int, cgWid: Int) -> String? {
        var cache = loadCache()
        if let dir = cache[label] { return dir }
        guard AX.trusted, let pid = Apps.pid(bundle) else { return nil }

        let opened = Script.run("""
        tell application "\(appName)"
          tell window id \(scriptedID)
            set oldIndex to active tab index
            make new tab with properties {URL:"chrome://version"}
            return oldIndex
          end tell
        end tell
        """)
        guard opened.ok else { return nil }
        defer {
            _ = Script.run("""
            tell application "\(appName)"
              tell window id \(scriptedID)
                close (every tab whose URL starts with "chrome://version")
                set active tab index to \(Int(opened.out) ?? 1)
              end tell
            end tell
            """)
        }

        // Chrome only builds the accessibility tree of web content once a client asks for it.
        AX.set(AXUIElementCreateApplication(pid), "AXManualAccessibility", kCFBooleanTrue)
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.6)
            guard let win = AX.window(pid: pid, wid: cgWid) else { continue }
            let path = AX.findString(in: win) { $0.hasPrefix("/") && $0.contains(userDataMarker) }
            if let path, let dir = TitleParsing.chromiumProfileDir(fromPath: path, userDataMarker: userDataMarker) {
                cache[label] = dir
                saveCache(cache)
                return dir
            }
        }
        return nil
    }

    static func open(_ entry: WindowEntry) -> OpenedWindow? {
        guard let b = entry.browser else { return nil }
        if !isRunning {
            Apps.launch(bundle: bundle)
            Thread.sleep(forTimeInterval: 4)
        }
        let before = Set(scriptedIDs(app: appName))
        let axBefore = axWindowIDs(bundle: bundle)
        var args = ["-n", "-b", bundle, "--args", "--new-window"]
        if let dir = b.profileDir ?? b.profileLabel.flatMap({ loadCache()[$0] }) {
            args.append("--profile-directory=\(dir)")
        }
        if b.incognito { args.append("--incognito") }
        let urls = b.tabs.map(\.url).filter { !$0.isEmpty }
        run("/usr/bin/open", args + (urls.isEmpty ? ["chrome://newtab/"] : urls))
        guard let id = waitForNewWindow(app: appName, before: before) else { return nil }
        _ = Script.run("tell application \"\(appName)\" to set bounds of window id \(id) to \(asBounds(entry.bounds))")
        if b.activeTab >= 1 && b.activeTab <= max(urls.count, 1) {
            _ = Script.run("tell application \"\(appName)\" to set active tab index of window id \(id) to \(b.activeTab)")
        }
        return OpenedWindow(scriptedID: id, element: newAXWindow(bundle: bundle, before: axBefore))
    }

    static func setMinimized(_ id: Int) {
        _ = Script.run("tell application \"\(appName)\" to set minimized of window id \(id) to true")
    }

    static func close(_ id: Int) {
        _ = Script.run("tell application \"\(appName)\" to close window id \(id)")
    }
}

// MARK: - Safari

enum Safari {
    static let bundle = "com.apple.Safari"
    static let appName = "Safari"

    static var isRunning: Bool { Apps.running(bundle) != nil }

    /// Windows Safari cannot script (e.g. a video playing full screen) raise errors and are skipped.
    static func windows() -> [ScriptedWindow] {
        guard isRunning else { return [] }
        let r = Script.run("""
        set S to "\(S)"
        set out to ""
        tell application "\(appName)"
          repeat with w in windows
            try
              set b to bounds of w
              set ts to tabs of w
              set chunk to "W" & S & (id of w) & S & (item 1 of b) & S & (item 2 of b) & S & (item 3 of b) & S & (item 4 of b) & S & "false" & S & (miniaturized of w) & S & (index of current tab of w) & S & (name of w) & linefeed
              repeat with t in ts
                set u to URL of t
                if u is missing value then set u to ""
                set chunk to chunk & "T" & S & u & S & (name of t) & linefeed
              end repeat
              set out to out & chunk
            end try
          end repeat
        end tell
        return out
        """)
        return r.ok ? ScriptedWindowParser.parse(r.out) : []
    }

    /// Safari's File menu starts with "New Window", which has one submenu item per profile when
    /// profiles exist. The menu is addressed by position, never by its translated title.
    static func profileMenuItems() -> [(title: String, element: AXUIElement)] {
        guard AX.trusted, let pid = Apps.pid(bundle) else { return [] }
        return AX.menuItems(pid: pid, path: [2, 0]).filter { !$0.title.isEmpty }
    }

    static func open(_ entry: WindowEntry) -> OpenedWindow? {
        guard let b = entry.browser else { return nil }
        if !isRunning {
            Apps.launch(bundle: bundle)
            Thread.sleep(forTimeInterval: 3)
        }
        let before = Set(scriptedIDs(app: appName))
        let axBefore = axWindowIDs(bundle: bundle)
        Apps.running(bundle)?.activate()
        Thread.sleep(forTimeInterval: 0.5)

        var opened = false
        if let label = b.profileLabel {
            let items = profileMenuItems()
            if let i = TitleParsing.menuItemIndex(forProfile: label, menuItems: items.map(\.title)) {
                opened = AX.press(items[i].element)
            }
        }
        if !opened { _ = Script.run("tell application \"\(appName)\" to make new document") }
        guard let id = waitForNewWindow(app: appName, before: before) else { return nil }

        let urls = b.tabs.map(\.url).filter { !$0.isEmpty }
        var script = "tell application \"\(appName)\"\n  set w to window id \(id)\n"
        if let first = urls.first { script += "  set URL of current tab of w to \(Script.quote(first))\n" }
        for u in urls.dropFirst() {
            script += "  tell w to make new tab at end of tabs with properties {URL:\(Script.quote(u))}\n"
        }
        if b.activeTab >= 1 && b.activeTab <= urls.count {
            script += "  set current tab of w to tab \(b.activeTab) of w\n"
        }
        script += "  set bounds of w to \(asBounds(entry.bounds))\nend tell"
        _ = Script.run(script)
        return OpenedWindow(scriptedID: id, element: newAXWindow(bundle: bundle, before: axBefore))
    }

    static func setMinimized(_ id: Int) {
        _ = Script.run("tell application \"\(appName)\" to set miniaturized of window id \(id) to true")
    }

    static func close(_ id: Int) {
        _ = Script.run("tell application \"\(appName)\" to close window id \(id)")
    }
}
