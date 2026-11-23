import AppKit
import WSnapCore

let wsnapVersion = "0.2.0"

func usage() {
    say(tr("""
    wsnap \(wsnapVersion) — save and restore your window layout across desktops, full-screen spaces and displays

    Usage:
      wsnap backup [--name NAME]        Save the current layout (optionally as a named layout)
      wsnap restore [SNAPSHOT]          Restore the newest snapshot, or a named / given one
            --dry-run                   Print what would be done without doing it
            --yes                       Skip the 5-second countdown
      wsnap list                        List saved snapshots
      wsnap show [SNAPSHOT]             Print what a snapshot contains
      wsnap doctor                      Check what works on this Mac and how to fix what does not
      wsnap version

    Snapshots are stored in \(Paths.snapshots.path)
    """, """
    wsnap \(wsnapVersion) — 备份和恢复窗口布局（多个桌面、全屏、多块显示器）

    用法：
      wsnap backup [--name 名字]        备份当前布局（可以起名，保存多套布局）
      wsnap restore [快照]              恢复最新的快照，或指定名字/文件的快照
            --dry-run                   只显示会做什么，不真的动手
            --yes                       跳过 5 秒倒计时
      wsnap list                        列出所有快照
      wsnap show [快照]                 显示快照里的内容
      wsnap doctor                      检查这台 Mac 上哪些功能可用、不可用的怎么解决
      wsnap version

    快照保存在 \(Paths.snapshots.path)
    """))
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func resolveOrExit(_ ref: String?) -> URL {
    guard let url = Store.resolve(ref) else {
        say(ref == nil ? tr("No snapshots yet. Run `wsnap backup` first.", "还没有快照，先运行 `wsnap backup`。")
                       : tr("No snapshot matches “\(ref!)”. See `wsnap list`.", "找不到快照「\(ref!)」，用 `wsnap list` 查看。"))
        exit(1)
    }
    return url
}

switch command {
case "_helper-window":
    // Internal: the throw-away window used while arranging full-screen spaces (see Tiling.swift).
    HelperWindow.runAsHelper(x: Int(args.first ?? "") ?? 100, y: Int(args.dropFirst().first ?? "") ?? 100)

case "backup":
    let name = option("--name")
    if !AX.trusted {
        say(tr("Note: without Accessibility permission, Chrome and Safari profiles cannot be recorded. Run `wsnap doctor` for details.",
               "提示：没有「辅助功能」权限，记录不了 Chrome 账户和 Safari 描述文件。运行 `wsnap doctor` 查看详情。"))
    }
    let snap = Backup.capture()
    do {
        let url = try Store.save(snap, name: name)
        Describe.snapshot(snap)
        say("\n" + tr("Saved: \(url.path)", "已保存：\(url.path)"))
    } catch {
        say(tr("Could not save the snapshot: \(error.localizedDescription)", "保存快照失败：\(error.localizedDescription)"))
        exit(1)
    }

case "restore":
    let dry = flag("--dry-run"), yes = flag("--yes")
    let url = resolveOrExit(args.first)
    exit(Restorer(dryRun: dry, assumeYes: yes).run(snapshotURL: url))

case "list":
    let all = Store.list()
    if all.isEmpty { say(tr("No snapshots yet.", "还没有快照。")) }
    for u in all {
        let n = (try? Store.load(u)).map { $0.allWindows.count }
        say(u.deletingPathExtension().lastPathComponent + (n.map { tr("  (\($0) windows)", "  （\($0) 个窗口）") } ?? tr("  (unreadable)", "  （读不了）")))
    }

case "show":
    let url = resolveOrExit(args.first)
    do { Describe.snapshot(try Store.load(url)) } catch {
        say(tr("Cannot read \(url.path): \(error.localizedDescription)", "读不了 \(url.path)：\(error.localizedDescription)"))
        exit(1)
    }

case "doctor":
    exit(Doctor.run())

case "version", "--version", "-v":
    say(wsnapVersion)

default:
    usage()
    exit(command == "help" || command == "--help" || command == "-h" ? 0 : 64)
}
