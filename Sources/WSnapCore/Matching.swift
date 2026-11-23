import Foundation

/// A browser window as reported by the browser's own scripting interface.
public struct ScriptedWindow: Equatable {
    public var id: Int
    public var bounds: Rect
    public var title: String
    public var minimized: Bool
    public var incognito: Bool
    public var activeTab: Int
    public var tabs: [Tab]

    public init(id: Int, bounds: Rect, title: String, minimized: Bool = false, incognito: Bool = false,
                activeTab: Int = 1, tabs: [Tab] = []) {
        self.id = id; self.bounds = bounds; self.title = title; self.minimized = minimized
        self.incognito = incognito; self.activeTab = activeTab; self.tabs = tabs
    }
}

public enum Matching {
    /// The system window list and the browser's scripting interface use different window ids.
    /// Pair them up by position and title. Returns the id of the best unused candidate.
    public static func bestMatch(bounds: Rect, title: String, candidates: [ScriptedWindow],
                                 used: Set<Int>) -> ScriptedWindow? {
        var best: ScriptedWindow?
        var bestScore = 0
        for c in candidates where !used.contains(c.id) {
            var score = 0
            if c.bounds.approxEquals(bounds) { score += 2 }
            if !title.isEmpty && (title == c.title || c.title.hasSuffix(title)) { score += 3 }
            if score > bestScore { best = c; bestScore = score }
        }
        return best
    }

    /// Two windows are "the same" for duplicate detection when they hold the same set of URLs.
    public static func sameTabs(_ a: [Tab], _ b: [Tab]) -> Bool {
        !a.isEmpty && Set(a.map(\.url)) == Set(b.map(\.url))
    }
}

/// Parses the line-based report the browser AppleScripts print:
///
///     W␞<id>␞<left>␞<top>␞<right>␞<bottom>␞<incognito>␞<minimized>␞<active tab>␞<title>
///     T␞<url>␞<title>
public enum ScriptedWindowParser {
    public static let separator = "\u{241E}"

    public static func parse(_ output: String) -> [ScriptedWindow] {
        var wins: [ScriptedWindow] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let p = line.components(separatedBy: separator)
            if p[0] == "W", p.count >= 10,
               let id = Int(p[1]), let l = Int(p[2]), let t = Int(p[3]), let r = Int(p[4]), let b = Int(p[5]) {
                wins.append(ScriptedWindow(
                    id: id, bounds: Rect(x: l, y: t, w: r - l, h: b - t),
                    title: p[9...].joined(separator: separator),
                    minimized: p[7] == "true", incognito: p[6] == "true",
                    activeTab: Int(p[8]) ?? 1, tabs: []))
            } else if p[0] == "T", p.count >= 3, !wins.isEmpty {
                wins[wins.count - 1].tabs.append(Tab(url: p[1], title: p[2...].joined(separator: separator)))
            }
        }
        return wins
    }
}
