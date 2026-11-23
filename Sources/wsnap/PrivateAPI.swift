import AppKit
import ApplicationServices

/// Every undocumented macOS call this tool makes lives in this one file.
///
/// Symbols are looked up at runtime with `dlsym` instead of being linked. If Apple removes or
/// renames one in a future macOS, the lookup returns nil and the feature that needs it is
/// switched off (see `wsnap doctor`); the tool keeps working with what is left instead of
/// failing to launch.
enum PrivateAPI {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    /// `WSNAP_NO_PRIVATE_API=1` pretends every private symbol is gone, to exercise the fallbacks.
    private static let disabled = ProcessInfo.processInfo.environment["WSNAP_NO_PRIVATE_API"] != nil

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard !disabled, let p = dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    // --- WindowServer (SkyLight): read which Spaces exist and which window is on which Space.
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionFn.self)
    private static let copyManagedDisplaySpaces =
        symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
    private static let copySpacesForWindows =
        symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)

    // --- Accessibility (HIServices): window id of an AX element, and AX elements of windows
    //     that are on other Spaces.
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXCreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindowFn.self)
    private static let axCreateWithRemoteToken =
        symbol("_AXUIElementCreateWithRemoteToken", as: AXCreateWithRemoteTokenFn.self)

    // MARK: Capabilities

    static var canReadSpaces: Bool { mainConnection != nil && copyManagedDisplaySpaces != nil }
    static var canMapWindowsToSpaces: Bool { mainConnection != nil && copySpacesForWindows != nil }
    static var canGetAXWindowID: Bool { axGetWindow != nil }
    static var canReachOffSpaceWindows: Bool { axCreateWithRemoteToken != nil && axGetWindow != nil }

    /// Name and availability of each private symbol, for `wsnap doctor`.
    static var symbolReport: [(name: String, available: Bool)] {
        [("CGSMainConnectionID", mainConnection != nil),
         ("CGSCopyManagedDisplaySpaces", copyManagedDisplaySpaces != nil),
         ("CGSCopySpacesForWindows", copySpacesForWindows != nil),
         ("_AXUIElementGetWindow", axGetWindow != nil),
         ("_AXUIElementCreateWithRemoteToken", axCreateWithRemoteToken != nil)]
    }

    // MARK: Wrappers (all return nil when the symbol is gone or the reply has an unexpected shape)

    /// One dictionary per display, each listing its Spaces in Mission Control order.
    static func managedDisplaySpaces() -> [[String: Any]]? {
        guard let conn = mainConnection, let copy = copyManagedDisplaySpaces else { return nil }
        return copy(conn())?.takeRetainedValue() as? [[String: Any]]
    }

    /// Ids of the Spaces a window is on.
    static func spaces(forWindow wid: CGWindowID) -> [Int]? {
        guard let conn = mainConnection, let copy = copySpacesForWindows else { return nil }
        let all: Int32 = 7  // current | other | fullscreen spaces
        let arr = copy(conn(), all, [NSNumber(value: wid)] as CFArray)?.takeRetainedValue()
        return (arr as? [NSNumber])?.map(\.intValue)
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let get = axGetWindow else { return nil }
        var wid: CGWindowID = 0
        return get(element, &wid) == .success && wid != 0 ? wid : nil
    }

    /// The public AX API only lists windows on the current Space. Apps number their AX elements,
    /// so asking for elements by number finds the windows on every other Space too.
    static func offSpaceWindows(pid: pid_t, maxElementID: UInt64 = 3000) -> [AXUIElement] {
        guard let create = axCreateWithRemoteToken else { return [] }
        var found: [AXUIElement] = []
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        for id in 0..<maxElementID {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let el = create(token as CFData)?.takeRetainedValue() else { continue }
            var role: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success,
                  (role as? String) == (kAXWindowRole as String) else { continue }
            found.append(el)
        }
        return found
    }
}
