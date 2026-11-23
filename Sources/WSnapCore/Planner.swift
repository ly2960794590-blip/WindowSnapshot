import Foundation

/// What the machine looks like right now, as far as planning a restore is concerned.
public struct ScreenInfo: Equatable {
    public var uuid: String
    public var isMain: Bool
    public var frame: Rect
    public init(uuid: String, isMain: Bool, frame: Rect) {
        self.uuid = uuid; self.isMain = isMain; self.frame = frame
    }
}

public struct RestoreEnvironment {
    public var screens: [ScreenInfo]
    /// Number of regular desktops per display uuid.
    public var desktopCounts: [String: Int]
    /// False when Spaces cannot be read or switched; everything then goes to the current desktop.
    public var spacesAvailable: Bool

    public init(screens: [ScreenInfo], desktopCounts: [String: Int], spacesAvailable: Bool) {
        self.screens = screens; self.desktopCounts = desktopCounts; self.spacesAvailable = spacesAvailable
    }
}

public struct DesktopPlan: Equatable {
    public var number: Int
    public var windows: [WindowEntry]
}

public struct FullscreenPlan: Equatable {
    /// Desktop to stand on while creating the full-screen space.
    public var fromDesktop: Int
    public var space: SpaceEntry
}

public struct DisplayPlan: Equatable {
    /// uuid of the display to restore onto (the current one, which may differ from the snapshot's).
    public var uuid: String
    public var isMain: Bool
    public var desktops: [DesktopPlan]
    public var fullscreens: [FullscreenPlan]
    /// Mission Control order of the snapshot, to compare against the result of a restore.
    public var expectedOrder: [OrderItem]
}

public enum OrderItem: Equatable {
    case desktop(Int)
    /// A full-screen or Split View space, identified by the app of its first window.
    case window(WindowEntry)

    /// Comparable form: desktop number or bundle id.
    public var key: String {
        switch self {
        case .desktop(let n): return "desktop:\(n)"
        case .window(let e): return "app:\(e.bundle)"
        }
    }
}

/// Things the user has to know or do by hand. Kept as data so the wording can be localized
/// and the planner can be unit-tested.
public enum PlanNote: Equatable {
    case displayMissing(isMain: Bool)
    case desktopsMissing(isMain: Bool, wanted: Int, have: Int)
    case spacesUnavailable
}

public struct RestorePlan: Equatable {
    public var displays: [DisplayPlan]
    public var notes: [PlanNote]
}

public enum Planner {

    public static func plan(snapshot: Snapshot, environment env: RestoreEnvironment) -> RestorePlan {
        var plans: [DisplayPlan] = []
        var notes: [PlanNote] = []
        if !env.spacesAvailable { notes.append(.spacesUnavailable) }

        for saved in snapshot.displays {
            guard let screen = matchScreen(saved, snapshot: snapshot, env: env) else {
                notes.append(.displayMissing(isMain: saved.isMain))
                continue
            }
            let dx = screen.frame.x - saved.frame.x
            let dy = screen.frame.y - saved.frame.y
            let sameSize = screen.frame.w == saved.frame.w && screen.frame.h == saved.frame.h

            func place(_ e: WindowEntry) -> WindowEntry {
                var e = e
                e.bounds = e.bounds.offset(dx: dx, dy: dy)
                if !sameSize && !e.bounds.isThumbnail { e.bounds = clamp(e.bounds, into: screen.frame) }
                if let t = e.tileRect { e.tileRect = t.offset(dx: dx, dy: dy) }
                return e
            }

            let wanted = saved.spaces.filter { $0.kind == .desktop }.count
            let have = env.spacesAvailable ? max(env.desktopCounts[screen.uuid] ?? 1, 1) : 1
            if env.spacesAvailable && have < wanted {
                notes.append(.desktopsMissing(isMain: saved.isMain, wanted: wanted, have: have))
            }

            var desktops: [Int: [WindowEntry]] = [:]
            var fullscreens: [FullscreenPlan] = []
            var order: [OrderItem] = []

            for sp in saved.spaces {
                switch sp.kind {
                case .desktop:
                    let n = sp.desktop ?? 1
                    order.append(.desktop(n))
                    // Desktops that no longer exist fold into the last one instead of being dropped.
                    desktops[min(n, have), default: []] += sp.windows.map(place)
                case .fullscreen, .split:
                    guard !sp.windows.isEmpty else { continue }
                    let after = sp.afterDesktop ?? wanted
                    // A Split View is identified by its left window.
                    let leading = sp.windows.min { ($0.tileRect?.x ?? 0) < ($1.tileRect?.x ?? 0) } ?? sp.windows[0]
                    order.append(.window(leading))
                    var moved = sp
                    moved.windows = sp.windows.map(place)
                    fullscreens.append(FullscreenPlan(fromDesktop: min(max(after, 1), have), space: moved))
                }
            }
            let desktopPlans = desktops.keys.sorted()
                .map { DesktopPlan(number: $0, windows: desktops[$0] ?? []) }
                .filter { !$0.windows.isEmpty }
            plans.append(DisplayPlan(uuid: screen.uuid, isMain: screen.isMain,
                                     desktops: desktopPlans, fullscreens: fullscreens, expectedOrder: order))
        }
        return RestorePlan(displays: plans, notes: notes)
    }

    /// Same physical display if it is still connected. A snapshot from a single-display setup
    /// restored on another single-display setup (new Mac, replaced monitor) maps onto that one display.
    static func matchScreen(_ saved: DisplayEntry, snapshot: Snapshot, env: RestoreEnvironment) -> ScreenInfo? {
        if let exact = env.screens.first(where: { $0.uuid == saved.uuid }) { return exact }
        if snapshot.displays.count == 1 && env.screens.count == 1 { return env.screens[0] }
        return nil
    }

    /// Shrinks and moves a window so it lies fully inside `frame`.
    public static func clamp(_ r: Rect, into frame: Rect) -> Rect {
        var r = r
        r.w = min(r.w, frame.w)
        r.h = min(r.h, frame.h)
        r.x = min(max(r.x, frame.x), frame.x + frame.w - r.w)
        r.y = min(max(r.y, frame.y), frame.y + frame.h - r.h)
        return r
    }
}
