import AppKit
import WSnapCore

enum Store {
    static func save(_ snap: Snapshot, name: String?) throws -> URL {
        Paths.ensure()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var file = f.string(from: Date())
        if let name, !name.isEmpty {
            let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
            file += "-" + String(safe)
        }
        let url = Paths.snapshots.appendingPathComponent(file + ".json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(snap).write(to: url)
        return url
    }

    /// Newest first.
    static func list() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Accepts a path, a file name, or a layout name given to `backup --name`; nil means newest.
    static func resolve(_ ref: String?) -> URL? {
        let all = list()
        guard let ref else { return all.first }
        if FileManager.default.fileExists(atPath: ref) { return URL(fileURLWithPath: ref) }
        return all.first { $0.lastPathComponent == ref || $0.deletingPathExtension().lastPathComponent == ref }
            ?? all.first { $0.deletingPathExtension().lastPathComponent.hasSuffix("-" + ref) }
    }

    static func load(_ url: URL) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    }
}

enum Backup {
    /// Processes that own layer-0 windows but are part of the system UI, by bundle id
    /// (bundle ids, unlike app names, are not translated).
    static let ignoredBundles: Set<String> = [
        "com.apple.WindowManager", "com.apple.dock", "com.apple.loginwindow", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.systemuiserver",
        "com.apple.screencaptureui", "com.apple.TextInputMenuAgent", "com.apple.wallpaper.agent",
        "com.apple.Terminal", "com.googlecode.iterm2",
    ]

    static func capture() -> Snapshot {
        let spacesOK = Spaces.available
        let displays = Spaces.displays()
        let screens = Screens.all()

        var windows = Spaces.windows().filter { w in
            !w.bundle.isEmpty && !ignoredBundles.contains(w.bundle)
                && NSRunningApplication(processIdentifier: w.pid)?.activationPolicy == .regular
                && w.bounds.w >= 100 && w.bounds.h >= 100
        }
        // A Stage Manager thumbnail is not recorded when the same app has a real window elsewhere.
        let appsWithRealWindow = Set(windows.filter { !$0.bounds.isThumbnail }.map(\.bundle))
        windows = windows.filter { !$0.bounds.isThumbnail || !appsWithRealWindow.contains($0.bundle) }

        let chromeWindows = Chrome.windows()
        let chromeLabels = chromeWindows.isEmpty ? [:] : Chrome.profileLabels()
        let safariWindows = Safari.windows()
        let safariMenu = safariWindows.isEmpty ? [] : Safari.profileMenuItems().map(\.title)
        var usedChrome = Set<Int>(), usedSafari = Set<Int>()

        func entry(for w: SysWindow) -> WindowEntry? {
            var e = WindowEntry(app: w.owner, bundle: w.bundle, appPath: w.appPath, title: w.title, bounds: w.bounds)
            if w.bundle == Chrome.bundle {
                guard let m = Matching.bestMatch(bounds: w.bounds, title: w.title, candidates: chromeWindows, used: usedChrome)
                else { return nil }  // popups, bubbles, picture-in-picture
                usedChrome.insert(m.id)
                let label = chromeLabels[w.wid]
                let dir = label.flatMap { Chrome.profileDir(label: $0, scriptedID: m.id, cgWid: w.wid) }
                e.title = m.title
                e.minimized = m.minimized
                e.browser = BrowserState(kind: .chrome, profileLabel: label, profileDir: dir, incognito: m.incognito,
                                         activeTab: m.activeTab, tabs: m.tabs)
            } else if w.bundle == Safari.bundle {
                guard let m = Matching.bestMatch(bounds: w.bounds, title: w.title, candidates: safariWindows, used: usedSafari)
                else { return nil }  // e.g. a video in full screen
                usedSafari.insert(m.id)
                e.title = m.title
                e.minimized = m.minimized
                e.browser = BrowserState(kind: .safari,
                                         profileLabel: TitleParsing.safariProfile(windowTitle: m.title, menuItems: safariMenu),
                                         profileDir: nil, incognito: false, activeTab: m.activeTab, tabs: m.tabs)
            }
            return e
        }

        var out: [DisplayEntry] = []
        for d in displays {
            let screen = screens.first { $0.uuid == d.uuid }
            var spaces: [SpaceEntry] = []
            var desktopNo = 0
            for s in d.spaces {
                if s.isDesktop {
                    desktopNo += 1
                    let ws = windows.filter { $0.spaces.contains(s.id) }.compactMap(entry(for:))
                    spaces.append(SpaceEntry(kind: .desktop, desktop: desktopNo, windows: ws))
                } else {
                    var ws: [WindowEntry] = []
                    for t in s.tiles {
                        guard let w = windows.first(where: { $0.wid == t.wid }), var e = entry(for: w) else { continue }
                        e.tileRect = t.rect
                        ws.append(e)
                    }
                    if ws.isEmpty { continue }  // nothing restorable in this space
                    spaces.append(SpaceEntry(kind: ws.count > 1 ? .split : .fullscreen, afterDesktop: desktopNo, windows: ws))
                }
            }
            out.append(DisplayEntry(uuid: d.uuid, isMain: screen?.isMain ?? (out.isEmpty),
                                    frame: screen?.frame ?? Rect(x: 0, y: 0, w: 0, h: 0), spaces: spaces))
        }

        // Minimized browser windows are on no Space; keep them on the first desktop, minimized.
        if !out.isEmpty, let first = out[0].spaces.firstIndex(where: { $0.kind == .desktop }) {
            for m in chromeWindows where !usedChrome.contains(m.id) && m.minimized {
                out[0].spaces[first].windows.append(WindowEntry(
                    app: Chrome.appName, bundle: Chrome.bundle, appPath: "", title: m.title, bounds: m.bounds, minimized: true,
                    browser: BrowserState(kind: .chrome, profileLabel: nil, profileDir: nil, incognito: m.incognito,
                                          activeTab: m.activeTab, tabs: m.tabs)))
            }
            for m in safariWindows where !usedSafari.contains(m.id) && m.minimized {
                out[0].spaces[first].windows.append(WindowEntry(
                    app: Safari.appName, bundle: Safari.bundle, appPath: "", title: m.title, bounds: m.bounds, minimized: true,
                    browser: BrowserState(kind: .safari,
                                          profileLabel: TitleParsing.safariProfile(windowTitle: m.title, menuItems: safariMenu),
                                          profileDir: nil, incognito: false, activeTab: m.activeTab, tabs: m.tabs)))
            }
        }

        return Snapshot(created: localTimestamp(), macOS: macOSVersionString(),
                        spacesRecorded: spacesOK, displays: out)
    }
}

// MARK: - Human-readable summary

enum Describe {
    static func displayName(isMain: Bool) -> String {
        isMain ? tr("Main display", "主屏幕") : tr("External display", "外接显示器")
    }

    static func label(_ e: WindowEntry) -> String {
        guard let b = e.browser else { return e.app }
        let name = b.kind == .chrome ? "Chrome" : "Safari"
        if b.incognito { return "\(name) [\(tr("incognito", "无痕"))]" }
        return b.profileLabel.map { "\(name) [\($0)]" } ?? name
    }

    static func window(_ e: WindowEntry) -> String {
        var s = label(e)
        if let b = e.browser {
            s += tr(", \(b.tabs.count) tab(s)", "，\(b.tabs.count) 个标签页")
        } else if !e.title.isEmpty {
            s += " “\(e.title)”"
        }
        if e.bounds.isThumbnail {
            s += tr("  (Stage Manager thumbnail, size not recorded)", "  （台前调度缩略图，不记录大小）")
        } else {
            s += tr("  at (\(e.bounds.x),\(e.bounds.y)) size \(e.bounds.w)×\(e.bounds.h)",
                    "  位置 (\(e.bounds.x),\(e.bounds.y)) 大小 \(e.bounds.w)×\(e.bounds.h)")
        }
        if e.minimized { s += tr("  [minimized]", "  [最小化]") }
        return s
    }

    static func snapshot(_ snap: Snapshot, tabs: Bool = true) {
        say(tr("Snapshot of \(snap.created), macOS \(snap.macOS)", "快照时间 \(snap.created)，macOS \(snap.macOS)"))
        if !snap.spacesRecorded {
            say(tr("  ! Desktops and full-screen spaces could not be read; only window positions were recorded.",
                   "  ！读不到桌面和全屏信息，只记录了窗口位置。"))
        }
        for d in snap.displays {
            say("\n[\(displayName(isMain: d.isMain))] \(d.frame.w)×\(d.frame.h)")
            for sp in d.spaces {
                switch sp.kind {
                case .desktop: say("  " + tr("Desktop \(sp.desktop ?? 1)", "桌面 \(sp.desktop ?? 1)"))
                case .fullscreen: say("  " + tr("Full screen", "全屏"))
                case .split: say("  " + tr("Split View", "分屏"))
                }
                if sp.windows.isEmpty { say("      " + tr("(empty)", "（空）")) }
                for e in sp.windows {
                    var side = ""
                    if sp.kind == .split, let t = e.tileRect {
                        side = t.x <= d.frame.x ? tr("left:  ", "左边：") : tr("right: ", "右边：")
                    }
                    say("      " + side + window(e))
                    if tabs, let b = e.browser {
                        for t in b.tabs { say("          - " + String((t.title.isEmpty ? t.url : t.title).prefix(60))) }
                    }
                }
            }
        }
    }
}

func localTimestamp() -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}
