import AppKit
import WSnapCore

// MARK: - Localized output

/// Picks the Chinese text on a Chinese system and the English text everywhere else.
/// User-facing strings only; nothing the tool *reads* from the system may depend on language.
let useChinese: Bool = {
    if let forced = ProcessInfo.processInfo.environment["WSNAP_LANG"] { return forced.hasPrefix("zh") }
    return (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
}()

func tr(_ en: String, _ zh: String) -> String { useChinese ? zh : en }

let debugEnabled = ProcessInfo.processInfo.environment["WSNAP_DEBUG"] != nil

/// Extra detail for bug reports: `WSNAP_DEBUG=1 wsnap restore`.
func debug(_ s: @autoclosure () -> String) {
    if debugEnabled { FileHandle.standardError.write(("[debug] " + s() + "\n").data(using: .utf8)!) }
}

func say(_ s: String = "") {
    print(s)
    fflush(stdout)
}

// MARK: - Files

enum Paths {
    static let dataDir: URL = {
        if let custom = ProcessInfo.processInfo.environment["WSNAP_HOME"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WindowSnapshot", isDirectory: true)
    }()
    static var snapshots: URL { dataDir.appendingPathComponent("snapshots", isDirectory: true) }
    static var chromeProfiles: URL { dataDir.appendingPathComponent("chrome-profiles.json") }

    static func ensure() {
        try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
    }
}

// MARK: - Processes

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

enum Apps {
    static func running(_ bundle: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
    }

    static func pid(_ bundle: String) -> pid_t? { running(bundle)?.processIdentifier }

    /// Launches (or activates) an app and waits until it is running.
    @discardableResult
    static func launch(bundle: String, path: String = "") -> pid_t? {
        let ok: Bool
        if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
            ok = run("/usr/bin/open", [path]).status == 0
        } else {
            ok = run("/usr/bin/open", ["-b", bundle]).status == 0
        }
        guard ok else { return nil }
        for _ in 0..<40 {
            if let pid = pid(bundle) { return pid }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }
}

/// AppleScript is only used to talk to browsers (their tab lists are not available any other way).
enum Script {
    static func run(_ source: String) -> (ok: Bool, out: String) {
        let r = wsnap.run("/usr/bin/osascript", ["-e", source])
        var out = r.out
        if out.hasSuffix("\n") { out.removeLast() }
        return (r.status == 0, out)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Displays

struct SysScreen {
    let id: CGDirectDisplayID
    let uuid: String
    let isMain: Bool
    let frame: Rect

    var info: ScreenInfo { ScreenInfo(uuid: uuid, isMain: isMain, frame: frame) }
}

enum Screens {
    static func all() -> [SysScreen] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map { id in
            let b = CGDisplayBounds(id)
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
            return SysScreen(id: id, uuid: uuid, isMain: CGDisplayIsMain(id) != 0,
                             frame: Rect(x: Int(b.origin.x), y: Int(b.origin.y), w: Int(b.width), h: Int(b.height)))
        }
    }

    static var main: SysScreen? { all().first(where: \.isMain) }

    /// Mission Control shortcuts act on the display under the mouse pointer.
    static func moveMouse(toDisplay uuid: String) {
        guard let s = all().first(where: { $0.uuid == uuid }) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: s.frame.centerX, y: s.frame.centerY))
    }
}

// MARK: - Keyboard

enum Keyboard {
    static func hotkey(_ id: Int, defaultKeyCode: Int) -> Hotkey {
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
            .dictionary(forKey: "AppleSymbolicHotKeys")
        return Hotkey.parse(all?[String(id)] as? [String: Any], defaultKeyCode: defaultKeyCode)
    }

    static var moveLeftASpace: Hotkey { hotkey(Hotkey.moveLeftASpaceID, defaultKeyCode: Hotkey.leftArrowKeyCode) }
    static var moveRightASpace: Hotkey { hotkey(Hotkey.moveRightASpaceID, defaultKeyCode: Hotkey.rightArrowKeyCode) }

    static func press(_ key: Hotkey) {
        let src = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: UInt64(key.eventFlags))
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(key.keyCode), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

func macOSVersionString() -> String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
}
