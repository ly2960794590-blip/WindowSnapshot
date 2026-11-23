import Foundation

/// A rectangle in global screen coordinates (origin at the top-left of the main display).
public struct Rect: Codable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public func offset(dx: Int, dy: Int) -> Rect {
        Rect(x: x + dx, y: y + dy, w: w, h: h)
    }

    public func approxEquals(_ other: Rect, tolerance: Int = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(w - other.w) <= tolerance && abs(h - other.h) <= tolerance
    }

    /// Stage Manager shows inactive windows as small thumbnails; their on-screen
    /// size is not the window's real size, so it must never be restored.
    public var isThumbnail: Bool { w < 200 || h < 200 }

    public var centerX: Int { x + w / 2 }
    public var centerY: Int { y + h / 2 }

    public func contains(x px: Int, y py: Int) -> Bool {
        px >= x && px < x + w && py >= y && py < y + h
    }
}

public struct Tab: Codable, Equatable {
    public var url: String
    public var title: String
    public init(url: String, title: String) { self.url = url; self.title = title }
}

public enum BrowserKind: String, Codable {
    case chrome
    case safari
}

/// Browser-specific state of a window: its tabs and which profile it belongs to.
public struct BrowserState: Codable, Equatable {
    public var kind: BrowserKind
    /// Profile name as the browser shows it (Chrome: "Work", "Alex (Work)"; Safari: "Personal").
    public var profileLabel: String?
    /// Chrome only: on-disk profile directory, e.g. "Profile 1". Needed to reopen in the same profile.
    public var profileDir: String?
    public var incognito: Bool
    /// 1-based index of the selected tab.
    public var activeTab: Int
    public var tabs: [Tab]

    public init(kind: BrowserKind, profileLabel: String?, profileDir: String?, incognito: Bool,
                activeTab: Int, tabs: [Tab]) {
        self.kind = kind; self.profileLabel = profileLabel; self.profileDir = profileDir
        self.incognito = incognito; self.activeTab = activeTab; self.tabs = tabs
    }
}

public struct WindowEntry: Codable, Equatable {
    public var app: String
    public var bundle: String
    public var appPath: String
    public var title: String
    public var bounds: Rect
    public var minimized: Bool
    public var browser: BrowserState?
    /// Only for windows inside a Split View: the tile's rectangle.
    public var tileRect: Rect?

    public init(app: String, bundle: String, appPath: String, title: String, bounds: Rect,
                minimized: Bool = false, browser: BrowserState? = nil, tileRect: Rect? = nil) {
        self.app = app; self.bundle = bundle; self.appPath = appPath; self.title = title
        self.bounds = bounds; self.minimized = minimized; self.browser = browser; self.tileRect = tileRect
    }
}

public enum SpaceKind: String, Codable {
    /// A regular desktop ("Desktop 1", "Desktop 2", ...).
    case desktop
    /// A single window in native full screen.
    case fullscreen
    /// Two windows sharing a full-screen space (Split View).
    case split
}

public struct SpaceEntry: Codable, Equatable {
    public var kind: SpaceKind
    /// For `.desktop`: 1-based desktop number on its display.
    public var desktop: Int?
    /// For `.fullscreen` / `.split`: number of the desktop it sat after in Mission Control (0 = before all).
    public var afterDesktop: Int?
    public var windows: [WindowEntry]

    public init(kind: SpaceKind, desktop: Int? = nil, afterDesktop: Int? = nil, windows: [WindowEntry]) {
        self.kind = kind; self.desktop = desktop; self.afterDesktop = afterDesktop; self.windows = windows
    }
}

public struct DisplayEntry: Codable, Equatable {
    public var uuid: String
    public var isMain: Bool
    public var frame: Rect
    public var spaces: [SpaceEntry]

    public init(uuid: String, isMain: Bool, frame: Rect, spaces: [SpaceEntry]) {
        self.uuid = uuid; self.isMain = isMain; self.frame = frame; self.spaces = spaces
    }
}

public struct Snapshot: Codable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var created: String
    public var macOS: String
    /// False when the Spaces layout could not be read; everything is then recorded as one desktop per display.
    public var spacesRecorded: Bool
    public var displays: [DisplayEntry]

    public init(created: String, macOS: String, spacesRecorded: Bool, displays: [DisplayEntry]) {
        self.version = Snapshot.currentVersion
        self.created = created; self.macOS = macOS
        self.spacesRecorded = spacesRecorded; self.displays = displays
    }

    public var allWindows: [WindowEntry] {
        displays.flatMap { $0.spaces.flatMap { $0.windows } }
    }
}
