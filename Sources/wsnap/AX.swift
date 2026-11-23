import AppKit
import ApplicationServices
import WSnapCore

struct AXWindow {
    /// Window-server id; nil when the private id lookup is unavailable.
    let wid: Int?
    let element: AXUIElement
    var title: String { AX.string(element, kAXTitleAttribute) ?? "" }
}

/// Thin wrapper over the public Accessibility API (plus two optional private helpers).
enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func promptForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? { value(e, name) as? String }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        value(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    @discardableResult
    static func set(_ e: AXUIElement, _ name: String, _ v: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(e, name as CFString, v) == .success
    }

    @discardableResult
    static func press(_ e: AXUIElement) -> Bool {
        AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    /// All windows of an app: the ones on the current Space (public API) plus, when possible,
    /// the ones on other Spaces.
    static func windows(pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        var out: [AXWindow] = []
        var seen = Set<Int>()
        let onSpace = value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for el in onSpace + (PrivateAPI.canReachOffSpaceWindows ? PrivateAPI.offSpaceWindows(pid: pid) : []) {
            if let wid = PrivateAPI.windowID(of: el).map(Int.init) {
                if seen.insert(wid).inserted { out.append(AXWindow(wid: wid, element: el)) }
            } else if !PrivateAPI.canGetAXWindowID {
                out.append(AXWindow(wid: nil, element: el))
            }
        }
        return out
    }

    static func window(pid: pid_t, wid: Int) -> AXUIElement? {
        windows(pid: pid).first { $0.wid == wid }?.element
    }

    static func setFrame(_ el: AXUIElement, _ r: Rect) {
        var p = CGPoint(x: r.x, y: r.y)
        var s = CGSize(width: r.w, height: r.h)
        if let pv = AXValueCreate(.cgPoint, &p) { set(el, kAXPositionAttribute, pv) }
        if let sv = AXValueCreate(.cgSize, &s) { set(el, kAXSizeAttribute, sv) }
        // Moving to a display with another scale can change the size limits; apply position again.
        if let pv = AXValueCreate(.cgPoint, &p) { set(el, kAXPositionAttribute, pv) }
    }

    static func isFullscreen(_ el: AXUIElement) -> Bool {
        (value(el, "AXFullScreen") as? NSNumber)?.boolValue ?? false
    }

    static func setFullscreen(_ el: AXUIElement, _ on: Bool) {
        set(el, "AXFullScreen", (on ? kCFBooleanTrue : kCFBooleanFalse)!)
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
    }

    /// Depth-first search for a text value somewhere below `root`.
    static func findString(in root: AXUIElement, maxNodes: Int = 20000, where match: (String) -> Bool) -> String? {
        var visited = 0
        func walk(_ e: AXUIElement, _ depth: Int) -> String? {
            if depth > 80 || visited > maxNodes { return nil }
            visited += 1
            for a in [kAXValueAttribute as String, kAXTitleAttribute as String] {
                if let s = string(e, a), match(s) { return s }
            }
            for c in children(e) { if let hit = walk(c, depth + 1) { return hit } }
            return nil
        }
        return walk(root, 0)
    }

    /// Finds a menu item anywhere in an app's menu bar by its AXIdentifier (the selector name,
    /// e.g. "_tileLeft:"), which is the same in every language.
    static func menuItem(pid: pid_t, identifier: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = value(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            if depth > 6 { return nil }
            for k in children(e) {
                if string(k, kAXIdentifierAttribute) == identifier { return k }
                if let hit = find(k, depth + 1) { return hit }
            }
            return nil
        }
        return find(bar as! AXUIElement, 0)
    }

    /// Titles of the items of a menu, with their elements. `path` is a list of 0-based indexes
    /// starting at the menu bar: [2] is the third menu bar item's menu, [2, 0] the submenu of
    /// its first item. Indexes, unlike titles, are the same in every language.
    static func menuItems(pid: pid_t, path: [Int]) -> [(title: String, element: AXUIElement)] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = value(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        var items = children(bar as! AXUIElement)
        for (depth, index) in path.enumerated() {
            guard index < items.count, let menu = children(items[index]).first else { return [] }
            items = children(menu)
            if depth == path.count - 1 {
                return items.map { (string($0, kAXTitleAttribute) ?? "", $0) }
            }
        }
        return items.map { (string($0, kAXTitleAttribute) ?? "", $0) }
    }
}
