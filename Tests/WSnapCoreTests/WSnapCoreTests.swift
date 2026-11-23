import XCTest
@testable import WSnapCore

final class TitleParsingTests: XCTestCase {
    func testChromeProfileLabel() {
        XCTAssertEqual(TitleParsing.chromiumProfileLabel(axTitle: "Inbox - Gmail - Google Chrome - Alex (Work)", appName: "Google Chrome"), "Alex (Work)")
        XCTAssertEqual(TitleParsing.chromiumProfileLabel(axTitle: "Example Domain - Google Chrome - Shopping", appName: "Google Chrome"), "Shopping")
    }

    func testChromeSingleProfileHasNoLabel() {
        XCTAssertNil(TitleParsing.chromiumProfileLabel(axTitle: "Inbox - Gmail - Google Chrome", appName: "Google Chrome"))
        XCTAssertNil(TitleParsing.chromiumProfileLabel(axTitle: "", appName: "Google Chrome"))
    }

    func testChromeLabelUsesLastMarker() {
        // A page title can itself contain the marker text.
        let t = "How to - Google Chrome - Help - Google Chrome - Work"
        XCTAssertEqual(TitleParsing.chromiumProfileLabel(axTitle: t, appName: "Google Chrome"), "Work")
    }

    func testSafariProfileFromWindowTitle() {
        let zh = ["新建个人窗口", "新建工作窗口", "新建合作窗口", "新建游戏窗口"]
        XCTAssertEqual(TitleParsing.safariProfile(windowTitle: "游戏 — Example", menuItems: zh), "游戏")
        XCTAssertEqual(TitleParsing.safariProfile(windowTitle: "工作 — Apple", menuItems: zh), "工作")
        let de = ["Neues Privat-Fenster", "Neues Arbeit-Fenster"]
        XCTAssertEqual(TitleParsing.safariProfile(windowTitle: "Arbeit — Apple", menuItems: de), "Arbeit")
    }

    func testSafariTitleWithoutProfile() {
        let en = ["New Personal Window", "New Work Window"]
        XCTAssertNil(TitleParsing.safariProfile(windowTitle: "Apple", menuItems: en))
        // A page title with a dash is not a profile unless a menu item names it.
        XCTAssertNil(TitleParsing.safariProfile(windowTitle: "Release notes — Swift", menuItems: en))
        XCTAssertNil(TitleParsing.safariProfile(windowTitle: "Work — Apple", menuItems: []))
    }

    func testSafariMenuItemForProfile() {
        let en = ["New Personal Window", "New Work Window", "New Work 2 Window", "New Park Window"]
        XCTAssertEqual(TitleParsing.menuItemIndex(forProfile: "Work", menuItems: en), 1)
        XCTAssertEqual(TitleParsing.menuItemIndex(forProfile: "Work 2", menuItems: en), 2)
        XCTAssertEqual(TitleParsing.menuItemIndex(forProfile: "Park", menuItems: en), 3)
        XCTAssertNil(TitleParsing.menuItemIndex(forProfile: "Gone", menuItems: en))
        XCTAssertNil(TitleParsing.menuItemIndex(forProfile: "", menuItems: en))
        XCTAssertEqual(TitleParsing.menuItemIndex(forProfile: "合作", menuItems: ["新建工作窗口", "新建合作窗口"]), 1)
    }

    func testChromeProfileDirFromPath() {
        let marker = "/Google/Chrome/"
        XCTAssertEqual(TitleParsing.chromiumProfileDir(fromPath: "/Users/a/Library/Application Support/Google/Chrome/Profile 5", userDataMarker: marker), "Profile 5")
        XCTAssertEqual(TitleParsing.chromiumProfileDir(fromPath: "/Users/a/Library/Application Support/Google/Chrome/Default", userDataMarker: marker), "Default")
        XCTAssertNil(TitleParsing.chromiumProfileDir(fromPath: "/Applications/Google Chrome.app", userDataMarker: marker))
        XCTAssertNil(TitleParsing.chromiumProfileDir(fromPath: "--user-data-dir=x/Google/Chrome/Default", userDataMarker: marker))
    }
}

final class MatchingTests: XCTestCase {
    let a = ScriptedWindow(id: 1, bounds: Rect(x: 0, y: 0, w: 800, h: 600), title: "Inbox")
    let b = ScriptedWindow(id: 2, bounds: Rect(x: 800, y: 0, w: 800, h: 600), title: "Docs")

    func testMatchesByTitleAndBounds() {
        XCTAssertEqual(Matching.bestMatch(bounds: b.bounds, title: "Docs", candidates: [a, b], used: [])?.id, 2)
    }

    func testMatchesByBoundsWhenTitleUnavailable() {
        // Without Screen Recording permission the system reports empty titles.
        XCTAssertEqual(Matching.bestMatch(bounds: Rect(x: 801, y: 1, w: 800, h: 600), title: "", candidates: [a, b], used: [])?.id, 2)
    }

    func testTitleBeatsBounds() {
        XCTAssertEqual(Matching.bestMatch(bounds: a.bounds, title: "Docs", candidates: [a, b], used: [])?.id, 2)
    }

    func testUsedCandidatesAreSkippedAndNoMatchIsNil() {
        XCTAssertNil(Matching.bestMatch(bounds: a.bounds, title: "Inbox", candidates: [a], used: [1]))
        XCTAssertNil(Matching.bestMatch(bounds: Rect(x: 5, y: 5, w: 10, h: 10), title: "Popup", candidates: [a, b], used: []))
    }

    func testSameTabsIgnoresOrderAndTitles() {
        let x = [Tab(url: "https://a", title: "A"), Tab(url: "https://b", title: "B")]
        let y = [Tab(url: "https://b", title: ""), Tab(url: "https://a", title: "")]
        XCTAssertTrue(Matching.sameTabs(x, y))
        XCTAssertFalse(Matching.sameTabs(x, [x[0]]))
        XCTAssertFalse(Matching.sameTabs([], []))
    }

    func testParseScriptOutput() {
        let s = ScriptedWindowParser.separator
        let out = """
        W\(s)11\(s)10\(s)20\(s)810\(s)620\(s)false\(s)false\(s)2\(s)Docs
        T\(s)https://a.example\(s)A
        T\(s)https://b.example\(s)Docs
        W\(s)12\(s)-200\(s)-900\(s)400\(s)-300\(s)true\(s)true\(s)1\(s)Private
        T\(s)https://c.example\(s)Private
        garbage line
        """
        let wins = ScriptedWindowParser.parse(out)
        XCTAssertEqual(wins.count, 2)
        XCTAssertEqual(wins[0].bounds, Rect(x: 10, y: 20, w: 800, h: 600))
        XCTAssertEqual(wins[0].activeTab, 2)
        XCTAssertEqual(wins[0].tabs.map(\.url), ["https://a.example", "https://b.example"])
        XCTAssertEqual(wins[1].bounds, Rect(x: -200, y: -900, w: 600, h: 600))
        XCTAssertTrue(wins[1].incognito)
        XCTAssertTrue(wins[1].minimized)
    }
}

final class HotkeyTests: XCTestCase {
    func testMissingEntryMeansSystemDefault() {
        let h = Hotkey.parse(nil, defaultKeyCode: Hotkey.leftArrowKeyCode)
        XCTAssertEqual(h, Hotkey(keyCode: 123, modifiers: Hotkey.controlFlag, enabled: true))
    }

    func testEnabledOnlyEntryKeepsDefaultKey() {
        let h = Hotkey.parse(["enabled": true], defaultKeyCode: Hotkey.rightArrowKeyCode)
        XCTAssertEqual(h, Hotkey(keyCode: 124, modifiers: Hotkey.controlFlag, enabled: true))
    }

    func testArrowKeysGetFnAndNumpadFlags() {
        let arrow = Hotkey(keyCode: 124, modifiers: Hotkey.controlFlag, enabled: true)
        XCTAssertEqual(arrow.eventFlags, 0x40000 | 0x800000 | 0x200000)
        let letter = Hotkey(keyCode: 43, modifiers: Hotkey.controlFlag, enabled: true)
        XCTAssertEqual(letter.eventFlags, 0x40000)
    }

    func testCustomizedAndDisabled() {
        let entry: [String: Any] = ["enabled": false,
                                    "value": ["parameters": [65535, 43, 1_179_648], "type": "standard"]]
        let h = Hotkey.parse(entry, defaultKeyCode: 123)
        XCTAssertEqual(h, Hotkey(keyCode: 43, modifiers: 1_179_648, enabled: false))
    }
}

final class PlannerTests: XCTestCase {
    let mainFrame = Rect(x: 0, y: 0, w: 1440, h: 900)
    let extFrame = Rect(x: 1440, y: 0, w: 1920, h: 1080)

    func win(_ app: String, _ r: Rect) -> WindowEntry {
        WindowEntry(app: app, bundle: "test." + app, appPath: "", title: app, bounds: r)
    }

    func snapshot() -> Snapshot {
        let main = DisplayEntry(uuid: "MAIN", isMain: true, frame: mainFrame, spaces: [
            SpaceEntry(kind: .desktop, desktop: 1, windows: [win("Notes", Rect(x: 10, y: 40, w: 600, h: 500))]),
            SpaceEntry(kind: .fullscreen, afterDesktop: 1, windows: [win("Mail", Rect(x: 0, y: 0, w: 1440, h: 900))]),
            SpaceEntry(kind: .desktop, desktop: 2, windows: [win("Maps", Rect(x: 700, y: 40, w: 700, h: 800))]),
            SpaceEntry(kind: .fullscreen, afterDesktop: 2, windows: [win("Music", Rect(x: 0, y: 0, w: 1440, h: 900))]),
        ])
        let ext = DisplayEntry(uuid: "EXT", isMain: false, frame: extFrame, spaces: [
            SpaceEntry(kind: .desktop, desktop: 1, windows: [win("Xcode", Rect(x: 1500, y: 50, w: 1200, h: 900))]),
        ])
        return Snapshot(created: "now", macOS: "15.0", spacesRecorded: true, displays: [main, ext])
    }

    func env(screens: [ScreenInfo], counts: [String: Int], spaces: Bool = true) -> RestoreEnvironment {
        RestoreEnvironment(screens: screens, desktopCounts: counts, spacesAvailable: spaces)
    }

    func testSameSetupRestoresEverythingInPlace() {
        let e = env(screens: [ScreenInfo(uuid: "MAIN", isMain: true, frame: mainFrame),
                              ScreenInfo(uuid: "EXT", isMain: false, frame: extFrame)],
                    counts: ["MAIN": 2, "EXT": 1])
        let plan = Planner.plan(snapshot: snapshot(), environment: e)
        XCTAssertEqual(plan.displays.count, 2)
        XCTAssertEqual(plan.displays[0].desktops.map(\.number), [1, 2])
        XCTAssertEqual(plan.displays[0].fullscreens.map(\.fromDesktop), [1, 2])
        XCTAssertEqual(plan.displays[0].desktops[1].windows[0].bounds, Rect(x: 700, y: 40, w: 700, h: 800))
        XCTAssertEqual(plan.displays[1].desktops[0].windows[0].bounds, Rect(x: 1500, y: 50, w: 1200, h: 900))
        XCTAssertEqual(plan.displays[0].expectedOrder.map(\.key),
                       ["desktop:1", "app:test.Mail", "desktop:2", "app:test.Music"])
        XCTAssertEqual(plan.notes, [])
    }

    func testMissingExternalDisplayIsReportedAndSkipped() {
        let e = env(screens: [ScreenInfo(uuid: "MAIN", isMain: true, frame: mainFrame)], counts: ["MAIN": 2])
        let plan = Planner.plan(snapshot: snapshot(), environment: e)
        XCTAssertEqual(plan.displays.map(\.uuid), ["MAIN"])
        XCTAssertTrue(plan.notes.contains(.displayMissing(isMain: false)))
    }

    func testRearrangedDisplayShiftsWindows() {
        // The external display moved from the right of the main display to above it.
        let moved = Rect(x: -240, y: -1080, w: 1920, h: 1080)
        let e = env(screens: [ScreenInfo(uuid: "MAIN", isMain: true, frame: mainFrame),
                              ScreenInfo(uuid: "EXT", isMain: false, frame: moved)],
                    counts: ["MAIN": 2, "EXT": 1])
        let plan = Planner.plan(snapshot: snapshot(), environment: e)
        XCTAssertEqual(plan.displays[1].desktops[0].windows[0].bounds, Rect(x: -180, y: -1030, w: 1200, h: 900))
    }

    func testFewerDesktopsFoldIntoTheLastOne() {
        let e = env(screens: [ScreenInfo(uuid: "MAIN", isMain: true, frame: mainFrame),
                              ScreenInfo(uuid: "EXT", isMain: false, frame: extFrame)],
                    counts: ["MAIN": 1, "EXT": 1])
        let plan = Planner.plan(snapshot: snapshot(), environment: e)
        XCTAssertEqual(plan.displays[0].desktops.map(\.number), [1])
        XCTAssertEqual(plan.displays[0].desktops[0].windows.map(\.app), ["Notes", "Maps"])
        XCTAssertEqual(plan.displays[0].fullscreens.map(\.fromDesktop), [1, 1])
        XCTAssertTrue(plan.notes.contains(.desktopsMissing(isMain: true, wanted: 2, have: 1)))
    }

    func testWithoutSpacesEverythingGoesToOneDesktop() {
        let e = env(screens: [ScreenInfo(uuid: "MAIN", isMain: true, frame: mainFrame),
                              ScreenInfo(uuid: "EXT", isMain: false, frame: extFrame)],
                    counts: [:], spaces: false)
        let plan = Planner.plan(snapshot: snapshot(), environment: e)
        XCTAssertEqual(plan.displays[0].desktops.map(\.number), [1])
        XCTAssertEqual(plan.notes, [.spacesUnavailable])
    }

    func testSingleDisplaySnapshotMapsOntoADifferentSingleDisplay() {
        var s = snapshot()
        s.displays.removeLast()
        let smaller = Rect(x: 0, y: 0, w: 1280, h: 800)
        let e = env(screens: [ScreenInfo(uuid: "NEW-MAC", isMain: true, frame: smaller)], counts: ["NEW-MAC": 2])
        let plan = Planner.plan(snapshot: s, environment: e)
        XCTAssertEqual(plan.displays.map(\.uuid), ["NEW-MAC"])
        let maps = plan.displays[0].desktops[1].windows[0].bounds
        XCTAssertEqual(maps, Rect(x: 580, y: 0, w: 700, h: 800))  // pulled back inside the smaller screen
    }

    func testClamp() {
        let frame = Rect(x: 0, y: 0, w: 1000, h: 800)
        XCTAssertEqual(Planner.clamp(Rect(x: 900, y: 700, w: 400, h: 300), into: frame), Rect(x: 600, y: 500, w: 400, h: 300))
        XCTAssertEqual(Planner.clamp(Rect(x: -50, y: -50, w: 2000, h: 2000), into: frame), frame)
    }
}

final class ModelTests: XCTestCase {
    func testSnapshotRoundTripsThroughJSON() throws {
        let tabs = [Tab(url: "https://example.com", title: "Example")]
        let w = WindowEntry(app: "Chrome", bundle: "com.google.Chrome", appPath: "", title: "Example",
                            bounds: Rect(x: 1, y: 2, w: 800, h: 600),
                            browser: BrowserState(kind: .chrome, profileLabel: "Work", profileDir: "Profile 1",
                                                  incognito: false, activeTab: 1, tabs: tabs),
                            tileRect: Rect(x: 0, y: 0, w: 700, h: 900))
        let snap = Snapshot(created: "now", macOS: "15.0", spacesRecorded: true, displays: [
            DisplayEntry(uuid: "U", isMain: true, frame: Rect(x: 0, y: 0, w: 1440, h: 900),
                         spaces: [SpaceEntry(kind: .split, afterDesktop: 1, windows: [w, w])])])
        let data = try JSONEncoder().encode(snap)
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: data), snap)
        XCTAssertEqual(snap.version, Snapshot.currentVersion)
        XCTAssertEqual(snap.allWindows.count, 2)
    }

    func testThumbnailDetection() {
        XCTAssertTrue(Rect(x: 15, y: 380, w: 128, h: 146).isThumbnail)
        XCTAssertFalse(Rect(x: 0, y: 0, w: 664, h: 834).isThumbnail)
    }
}
