import AppKit
import ApplicationServices
import WSnapCore

final class Restorer {
    let dryRun: Bool
    let assumeYes: Bool
    private var notes: [String] = []
    private var displayUUID = ""
    private var displayName = ""

    init(dryRun: Bool, assumeYes: Bool) {
        self.dryRun = dryRun
        self.assumeYes = assumeYes
    }

    private func log(_ s: String) { say((dryRun ? tr("[dry run] ", "[预演] ") : "") + s) }
    private func note(_ s: String) { notes.append(s) }

    // MARK: Entry point

    func run(snapshotURL: URL) -> Int32 {
        let snap: Snapshot
        do { snap = try Store.load(snapshotURL) } catch {
            say(tr("Cannot read snapshot \(snapshotURL.path): \(error.localizedDescription)",
                   "读不了快照 \(snapshotURL.path)：\(error.localizedDescription)"))
            return 1
        }
        say(tr("Using snapshot \(snapshotURL.lastPathComponent) (taken \(snap.created))",
               "使用快照 \(snapshotURL.lastPathComponent)（备份于 \(snap.created)）"))

        if !dryRun && !AX.trusted {
            AX.promptForTrust()
            say(tr("""
                Accessibility permission is required to move windows and switch desktops.
                Open System Settings → Privacy & Security → Accessibility, enable your terminal app, then run this again.
                """, """
                移动窗口和切换桌面需要「辅助功能」权限。
                打开 系统设置 → 隐私与安全性 → 辅助功能，把你用的终端 App 打开，然后重新运行。
                """))
            return 2
        }

        // Can we actually move between desktops?
        var canSwitch = Spaces.available
        if canSwitch && !(Keyboard.moveLeftASpace.enabled && Keyboard.moveRightASpace.enabled) {
            canSwitch = false
            note(tr("""
                The “Move left/right a space” shortcuts are turned off, so desktops cannot be switched automatically and \
                everything was restored onto the current desktop. Turn them on in System Settings → Keyboard → \
                Keyboard Shortcuts → Mission Control, then run restore again.
                """, """
                「向左/向右移动一个空间」快捷键被关掉了，没法自动切换桌面，所有窗口都恢复到了当前桌面。\
                在 系统设置 → 键盘 → 键盘快捷键 → 调度中心 里打开它们，再运行一次恢复。
                """))
        }

        let displays = Spaces.displays()
        let env = RestoreEnvironment(
            screens: Screens.all().map(\.info),
            desktopCounts: Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.desktops.count) }),
            spacesAvailable: canSwitch)
        let plan = Planner.plan(snapshot: snap, environment: env)
        for n in plan.notes {
            // When only the shortcuts are off, the more specific note above already explains it.
            if n == .spacesUnavailable && Spaces.available { continue }
            note(render(n))
        }

        closeDuplicates(of: snap)

        if !dryRun && !assumeYes {
            say(tr("Starting in 5 seconds. Desktops will switch by themselves; please leave the mouse and keyboard alone (1–2 minutes). Press Ctrl+C to cancel.",
                   "5 秒后开始恢复，过程中会自动切换桌面，请别动鼠标键盘（大约 1–2 分钟）。按 Ctrl+C 取消。"))
            for i in stride(from: 5, to: 0, by: -1) {
                say("  \(i)…")
                Thread.sleep(forTimeInterval: 1)
            }
        }

        for d in plan.displays {
            displayUUID = d.uuid
            displayName = Describe.displayName(isMain: d.isMain)
            say("")
            log("===== \(displayName) =====")
            for desk in d.desktops {
                guard goTo(desk.number) else {
                    note(tr("Could not switch to desktop \(desk.number) on the \(displayName); its windows were not restored.",
                            "切不到\(displayName)的桌面 \(desk.number)，上面的窗口没恢复。"))
                    continue
                }
                log(tr("Desktop \(desk.number):", "桌面 \(desk.number)："))
                for e in desk.windows { restoreOnDesktop(e) }
            }
            // A space built by tiling is inserted right after the desktop it was made from, so
            // the spaces that followed one desktop are created last-to-first.
            for desk in Set(d.fullscreens.map(\.fromDesktop)).sorted() {
                for fs in d.fullscreens.filter({ $0.fromDesktop == desk }).reversed() {
                    log(fs.space.kind == .split ? tr("Split View:", "分屏：") : tr("Full screen:", "全屏："))
                    if fs.space.kind == .split {
                        restoreSplit(fs)
                    } else {
                        restoreFullscreen(fs)
                    }
                }
            }
            if !dryRun { checkOrder(d) }
            _ = goTo(1)
        }

        if !dryRun, let main = Screens.main { Screens.moveMouse(toDisplay: main.uuid) }
        say("\n" + (dryRun ? tr("Dry run finished. Nothing was changed.", "预演结束，没有改动任何窗口。")
                            : tr("Restore finished.", "恢复完成。")))
        if !notes.isEmpty {
            say("\n" + tr("Things left for you:", "需要你手动处理的："))
            for n in notes { say("  · " + n) }
        }
        return 0
    }

    // MARK: Steps

    private func goTo(_ desktop: Int) -> Bool {
        if dryRun {
            log(tr("switch \(displayName) to desktop \(desktop)", "把\(displayName)切到桌面 \(desktop)"))
            return true
        }
        return Spaces.goToDesktop(desktop, onDisplay: displayUUID)
    }

    private struct Opened {
        let element: AXUIElement?
        let pid: pid_t
        let scriptedID: Int?
    }

    /// Opens one window on the current desktop at its saved position. Nil in a dry run or on failure.
    private func open(_ e: WindowEntry) -> Opened? {
        log("  " + tr("open ", "打开 ") + Describe.window(e))
        if dryRun { return nil }
        if let b = e.browser {
            guard let w = b.kind == .chrome ? Chrome.open(e) : Safari.open(e), let pid = Apps.pid(e.bundle) else {
                note(tr("\(Describe.label(e)) window could not be opened. Its pages:\n      ",
                        "\(Describe.label(e)) 窗口没打开成功，请手动打开：\n      ")
                     + b.tabs.map(\.url).joined(separator: "\n      "))
                return nil
            }
            if b.kind == .chrome, let label = b.profileLabel, b.profileDir == nil {
                note(tr("Could not tell which Chrome profile “\(label)” is on disk, so that window opened in Chrome's current profile.",
                        "认不出 Chrome 账户「\(label)」对应的文件夹，这个窗口开在了 Chrome 当前的账户里。"))
            }
            return Opened(element: w.element ?? focusedWindow(bundle: e.bundle), pid: pid, scriptedID: w.scriptedID)
        }
        guard let pid = Apps.launch(bundle: e.bundle, path: e.appPath) else {
            note(tr("\(e.app) could not be opened.", "\(e.app) 打不开，请手动打开。"))
            return nil
        }
        guard let el = findWindow(e, pid: pid) else {
            note(tr("\(e.app) opened without a window (it may be waiting at a sign-in screen).",
                    "\(e.app) 打开了但没有窗口（可能停在登录页），请手动调整。"))
            return nil
        }
        if !e.bounds.isThumbnail { AX.setFrame(el, e.bounds) }
        return Opened(element: el, pid: pid, scriptedID: nil)
    }

    private func restoreOnDesktop(_ e: WindowEntry) {
        if e.browser == nil && isFullscreenSomewhere(e.bundle) {
            log("  " + tr("\(e.app) is in full screen, left as is", "\(e.app) 现在是全屏，保持不动"))
            if !e.bounds.isThumbnail {
                note(tr("\(e.app) is in full screen now but was a normal window in the snapshot; leave full screen by hand if you want it back.",
                        "\(e.app) 现在是全屏，快照里它是普通窗口，需要的话请手动退出全屏。"))
            }
            return
        }
        guard let w = open(e) else { return }
        if e.minimized, let id = w.scriptedID, let b = e.browser {
            if b.kind == .chrome { Chrome.setMinimized(id) } else { Safari.setMinimized(id) }
        }
    }

    private func restoreFullscreen(_ fs: FullscreenPlan) {
        let e = fs.space.windows[0]
        if e.browser == nil && isFullscreenSomewhere(e.bundle) {
            log("  " + tr("\(e.app) is already in full screen, left as is", "\(e.app) 已经是全屏，保持不动"))
            return
        }
        guard goTo(fs.fromDesktop) else {
            note(tr("Could not switch desktops on the \(displayName); \(Describe.label(e)) was not put in full screen.",
                    "\(displayName)切不了桌面，\(Describe.label(e)) 的全屏没恢复。"))
            return
        }
        let opened = open(e)
        if dryRun { log("  " + tr("make it full screen", "设为全屏")); return }
        guard let opened, let element = opened.element else { return }
        if placeFullscreenAfterCurrentDesktop(element, pid: opened.pid) { return }
        if !enterFullscreen(element, bundle: e.bundle) {
            note(tr("\(Describe.label(e)) could not be put in full screen automatically; click its green button.",
                    "\(Describe.label(e)) 没能自动全屏，请点窗口左上角的绿色按钮。"))
        }
    }

    /// Full screen via "tile left + helper window" so the new space lands right after the
    /// current desktop instead of at the very end (see `Tiling`).
    private func placeFullscreenAfterCurrentDesktop(_ element: AXUIElement, pid: pid_t) -> Bool {
        guard Tiling.supported, let screen = Screens.all().first(where: { $0.uuid == displayUUID }),
              let helper = HelperWindow.spawn(onScreen: screen.frame) else {
            debug("placeFullscreen: tiling unsupported or helper window could not be created")
            return false
        }
        debug("placeFullscreen: helper window \(helper.wid) at \(String(describing: Tiling.bounds(ofWindow: helper.wid)))")
        defer { helper.close() }
        guard let wid = Tiling.tileLeft(element, pid: pid) else { return false }
        guard Tiling.choosePartner(helper.wid, for: wid) else {
            Tiling.cancel(primary: wid)
            return false
        }
        helper.close()
        return Tiling.waitUntilAlone(wid)
    }

    private func restoreSplit(_ fs: FullscreenPlan) {
        guard goTo(fs.fromDesktop) else {
            note(tr("Could not switch desktops on the \(displayName); the Split View was not restored.",
                    "\(displayName)切不了桌面，分屏没恢复。"))
            return
        }
        // Left window first; lay both out side by side so a failure still leaves a usable layout.
        let entries = fs.space.windows.sorted { ($0.tileRect?.x ?? 0) < ($1.tileRect?.x ?? 0) }.map { e -> WindowEntry in
            var e = e
            if let t = e.tileRect { e.bounds = Rect(x: t.x, y: t.y + 30, w: t.w, h: max(t.h - 30, 300)) }
            return e
        }
        let opened = entries.map { open($0) }
        let names = entries.map(Describe.label).joined(separator: " + ")
        if dryRun { log("  " + tr("join them into a Split View", "拼成分屏")); return }

        if opened.count == 2, let left = opened[0], let right = opened[1],
           let le = left.element, let re = right.element,
           let rightWid = PrivateAPI.windowID(of: re).map(Int.init),
           let leftWid = Tiling.tileLeft(le, pid: left.pid) {
            if Tiling.choosePartner(rightWid, for: leftWid) { return }
            Tiling.cancel(primary: leftWid)
        }
        note(tr("""
            Split View: \(names) could not be joined automatically; they are side by side on desktop \(fs.fromDesktop) of the \(displayName). \
            Hover the green button of the left window, choose “Tile Window to Left of Screen”, then click the other window.
            """, """
            分屏：\(names) 没能自动拼起来，已经在\(displayName)的桌面 \(fs.fromDesktop) 上左右摆好。\
            鼠标停在左边窗口的绿色按钮上，选「拼贴到屏幕左侧」，再点右边那个窗口。
            """))
    }

    /// Compares the Mission Control order after the restore with the snapshot's and tells the
    /// user only if they differ.
    private func checkOrder(_ d: DisplayPlan) {
        guard Spaces.available, let now = Spaces.display(d.uuid) else { return }
        let bundles = Dictionary(Spaces.windows().map { ($0.wid, $0.bundle) }, uniquingKeysWith: { a, _ in a })
        var actual: [String] = []
        var n = 0
        for s in now.spaces {
            if s.isDesktop {
                n += 1
                actual.append("desktop:\(n)")
            } else if let first = s.tiles.filter({ $0.wid != 0 }).min(by: { $0.rect.x < $1.rect.x }),
                      let bundle = bundles[first.wid] {
                actual.append("app:\(bundle)")
            }
        }
        let expected = d.expectedOrder.map(\.key)
        guard actual != expected else { return }
        let list = d.expectedOrder.map { item -> String in
            switch item {
            case .desktop(let n): return tr("Desktop \(n)", "桌面\(n)")
            case .window(let e): return Describe.label(e)
            }
        }.joined(separator: " → ")
        note(tr("\(displayName): the order of spaces differs from the snapshot, which had: \(list). Drag the thumbnails in Mission Control (F3) to rearrange.",
                "\(displayName)：空间的排列顺序和快照不一样，快照里是：\(list)。按 F3 打开调度中心，把顶部的缩略图拖到对应位置即可。"))
    }

    // MARK: Helpers

    private func isFullscreenSomewhere(_ bundle: String) -> Bool {
        let fs = Spaces.fullscreenSpaceIDs()
        guard !fs.isEmpty else { return false }
        return Spaces.windows().contains { $0.bundle == bundle && !fs.isDisjoint(with: $0.spaces) }
    }

    private func focusedWindow(bundle: String) -> AXUIElement? {
        guard let pid = Apps.pid(bundle) else { return nil }
        guard let v = AX.value(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func findWindow(_ e: WindowEntry, pid: pid_t) -> AXUIElement? {
        for _ in 0..<24 {
            let wins = AX.windows(pid: pid)
            if !wins.isEmpty {
                Thread.sleep(forTimeInterval: 0.6)
                if !e.title.isEmpty, let byTitle = wins.first(where: { $0.title == e.title }) { return byTitle.element }
                return focusedWindow(bundle: e.bundle) ?? wins[0].element
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private func enterFullscreen(_ el: AXUIElement, bundle: String) -> Bool {
        let before = Spaces.fullscreenSpaceIDs()
        Apps.running(bundle)?.activate()
        AX.raise(el)
        Thread.sleep(forTimeInterval: 0.5)
        AX.setFullscreen(el, true)
        // Large displays animate slowly; wait until either the window reports full screen or
        // a new full-screen space shows up.
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.5)
            if AX.isFullscreen(el) || !Spaces.fullscreenSpaceIDs().subtracting(before).isEmpty {
                Thread.sleep(forTimeInterval: 1.0)
                return true
            }
        }
        return false
    }

    /// Browsers often reopen their last windows after a reboot, all on one desktop. Windows that
    /// hold exactly the tabs of a saved window are closed and reopened in the right place.
    private func closeDuplicates(of snap: Snapshot) {
        let saved = snap.allWindows.compactMap(\.browser)
        func handle(_ kind: BrowserKind, _ name: String, _ current: [ScriptedWindow], close: (Int) -> Void) {
            let mine = saved.filter { $0.kind == kind }
            let dups = current.filter { w in mine.contains { Matching.sameTabs($0.tabs, w.tabs) } }
            guard !dups.isEmpty else { return }
            say(tr("\(name) already has \(dups.count) window(s) identical to the snapshot; closing them to reopen in the right place.",
                   "\(name) 里已有 \(dups.count) 个和快照一样的窗口，会关掉后按快照重新打开。"))
            for w in dups {
                log(tr("close duplicate: ", "关闭重复窗口：") + String(w.title.prefix(50)))
                if !dryRun { close(w.id) }
            }
            if !dryRun { Thread.sleep(forTimeInterval: 1) }
        }
        if saved.contains(where: { $0.kind == .chrome }) { handle(.chrome, "Chrome", Chrome.windows(), close: Chrome.close) }
        if saved.contains(where: { $0.kind == .safari }) { handle(.safari, "Safari", Safari.windows(), close: Safari.close) }
    }

    private func render(_ n: PlanNote) -> String {
        switch n {
        case .displayMissing(let isMain):
            let name = Describe.displayName(isMain: isMain)
            return tr("The \(name) from the snapshot is not connected, so its windows were skipped. Connect it and run restore again; windows already restored are not opened twice.",
                      "快照里的\(name)现在没接上，它上面的窗口没恢复。接上后再运行一次即可，已恢复的窗口不会重复打开。")
        case .desktopsMissing(let isMain, let wanted, let have):
            let name = Describe.displayName(isMain: isMain)
            return tr("The snapshot has \(wanted) desktops on the \(name) but there are only \(have) now; windows from the missing ones went to desktop \(have). Add desktops in Mission Control (F3 → “+”) and run again for an exact restore.",
                      "快照里\(name)有 \(wanted) 个桌面，现在只有 \(have) 个，多出来的桌面上的窗口放到了桌面 \(have)。想完全一样，按 F3 → 右上角「+」补上桌面后再运行一次。")
        case .spacesUnavailable:
            return tr("Desktops could not be read or switched on this system, so all windows were restored onto the current desktop.",
                      "这台电脑上读不到或切不了桌面，所有窗口都恢复到了当前桌面。")
        }
    }
}
