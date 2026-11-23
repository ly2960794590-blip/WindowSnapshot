import AppKit
import WSnapCore

/// `wsnap doctor`: checks every capability the tool relies on, on this machine, and says what
/// to do about each one that is missing. Its output is what a bug report should include.
enum Doctor {
    private enum Level { case ok, warn, fail }

    private static var worst = Level.ok

    private static func line(_ level: Level, _ what: String, _ hint: String = "") {
        let mark: String
        switch level {
        case .ok: mark = "[ ok ]"
        case .warn: mark = "[warn]"; if worst == .ok { worst = .warn }
        case .fail: mark = "[FAIL]"; worst = .fail
        }
        say("\(mark) \(what)")
        if !hint.isEmpty && level != .ok { say("       → \(hint)") }
    }

    static func run() -> Int32 {
        say("wsnap \(wsnapVersion), macOS \(macOSVersionString()), \(Locale.preferredLanguages.first ?? "?")\n")

        // 1. Private system calls
        say(tr("Undocumented system calls", "未公开的系统接口"))
        for s in PrivateAPI.symbolReport {
            line(s.available ? .ok : .warn, s.name,
                 tr("missing on this macOS; the feature that needs it is turned off", "这个 macOS 版本里没有了，依赖它的功能会自动关闭"))
        }

        // 2. Spaces
        say("\n" + tr("Desktops and full-screen spaces", "桌面和全屏"))
        if Spaces.available {
            let ds = Spaces.displays()
            let summary = ds.map { "\($0.desktops.count)+\($0.spaces.count - $0.desktops.count)" }.joined(separator: ", ")
            line(.ok, tr("layout readable: \(ds.count) display(s), desktops+full-screen spaces per display: \(summary)",
                         "能读到布局：\(ds.count) 块屏幕，每块屏幕的 桌面+全屏 数量：\(summary)"))
        } else {
            line(.warn, tr("layout not readable", "读不到布局"),
                 tr("backup records window positions only; restore puts everything on the current desktop",
                    "备份只记录窗口位置，恢复时所有窗口放在当前桌面"))
        }
        if Screens.all().count > 1 {
            line(Spaces.displaysHaveSeparateSpaces ? .ok : .warn,
                 tr("“Displays have separate Spaces” is on", "「显示器具有单独的空间」已打开"),
                 tr("it is off: all displays switch desktops together, per-display restore is less exact",
                    "现在是关的：所有屏幕会一起切换桌面，按屏幕恢复会不太准"))
        }
        let l = Keyboard.moveLeftASpace, r = Keyboard.moveRightASpace
        line(l.enabled && r.enabled ? .ok : .fail,
             tr("“Move left/right a space” shortcuts enabled (key codes \(l.keyCode)/\(r.keyCode))",
                "「向左/向右移动一个空间」快捷键已启用（键码 \(l.keyCode)/\(r.keyCode)）"),
             tr("enable them in System Settings → Keyboard → Keyboard Shortcuts → Mission Control",
                "在 系统设置 → 键盘 → 键盘快捷键 → 调度中心 里打开"))

        // 3. Permissions
        say("\n" + tr("Permissions", "权限"))
        line(AX.trusted ? .ok : .fail, tr("Accessibility", "辅助功能"),
             tr("System Settings → Privacy & Security → Accessibility → enable your terminal app",
                "系统设置 → 隐私与安全性 → 辅助功能 → 打开你用的终端 App"))
        let titleProbe = Spaces.windows().contains { !$0.title.isEmpty }
        line(titleProbe ? .ok : .warn, tr("window titles readable (Screen Recording)", "能读窗口标题（屏幕录制权限）"),
             tr("optional; without it windows are matched by position only", "可选；没有的话只按位置匹配窗口"))

        // 4. Browsers
        say("\n" + tr("Browsers", "浏览器"))
        if Chrome.isRunning {
            let wins = Chrome.windows()
            line(wins.isEmpty ? .warn : .ok, tr("Chrome scripting: \(wins.count) window(s)", "Chrome 脚本控制：\(wins.count) 个窗口"),
                 tr("allow “Automation → Google Chrome” for your terminal app when macOS asks",
                    "系统询问时，允许终端 App「自动化 → Google Chrome」"))
            let labels = Set(Chrome.profileLabels().values)
            line(.ok, tr("Chrome profiles seen: ", "识别到的 Chrome 账户：") + (labels.isEmpty ? tr("(single profile)", "（只有一个账户）") : labels.sorted().joined(separator: ", ")))
        } else {
            line(.ok, tr("Chrome is not running (skipped)", "Chrome 没在运行（跳过）"))
        }
        if Safari.isRunning {
            let wins = Safari.windows()
            line(wins.isEmpty ? .warn : .ok, tr("Safari scripting: \(wins.count) window(s)", "Safari 脚本控制：\(wins.count) 个窗口"),
                 tr("allow “Automation → Safari” for your terminal app when macOS asks", "系统询问时，允许终端 App「自动化 → Safari」"))
            let items = Safari.profileMenuItems().map(\.title)
            line(.ok, tr("Safari profile menu items: ", "Safari 描述文件菜单项：") + (items.isEmpty ? tr("(no profiles)", "（没有描述文件）") : items.joined(separator: ", ")))
        } else {
            line(.ok, tr("Safari is not running (skipped)", "Safari 没在运行（跳过）"))
        }

        say("")
        switch worst {
        case .ok: say(tr("Everything this tool needs is available.", "需要的功能都可用。"))
        case .warn: say(tr("Usable, with the reduced features marked [warn] above.", "可以用，上面标 [warn] 的功能会降级。"))
        case .fail: say(tr("Fix the items marked [FAIL] above before restoring.", "恢复之前请先解决上面标 [FAIL] 的项目。"))
        }
        return worst == .fail ? 1 : 0
    }
}
