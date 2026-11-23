import Foundation

/// Language-independent parsing of window titles and menu item names.
/// Nothing in here may depend on a specific UI language.
public enum TitleParsing {

    /// Chrome's accessibility title is "<page> - Google Chrome - <profile>" when several
    /// profiles exist and "<page> - Google Chrome" otherwise. The app name is a brand name
    /// and is the same in every language.
    public static func chromiumProfileLabel(axTitle: String, appName: String) -> String? {
        let marker = " - \(appName) - "
        guard let r = axTitle.range(of: marker, options: .backwards) else { return nil }
        let label = axTitle[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    /// Safari prefixes window titles with "<Profile> — " and lists one "New <Profile> Window"
    /// menu item per profile, with the wording translated ("新建<Profile>窗口",
    /// "Neues <Profile>-Fenster", ...). Rather than guessing the translated wording, the title
    /// prefix is accepted as a profile name only if some menu item contains it.
    public static func safariProfile(windowTitle: String, menuItems: [String]) -> String? {
        guard let r = windowTitle.range(of: " — ") else { return nil }
        let candidate = String(windowTitle[..<r.lowerBound])
        guard !candidate.isEmpty, menuItems.contains(where: { $0.contains(candidate) }) else { return nil }
        return candidate
    }

    /// Index of the "New <Profile> Window" item for a profile. Several items can contain the
    /// name ("Work" is inside "New Work 2 Window" too); the one with the least text around the
    /// name is the right one.
    public static func menuItemIndex(forProfile profile: String, menuItems: [String]) -> Int? {
        guard !profile.isEmpty else { return nil }
        return menuItems.enumerated()
            .filter { $0.element.contains(profile) }
            .min { $0.element.count < $1.element.count }?.offset
    }

    /// Extracts the profile directory name from the "Profile Path" shown on chrome://version.
    public static func chromiumProfileDir(fromPath path: String, userDataMarker: String) -> String? {
        guard path.hasPrefix("/"), let r = path.range(of: userDataMarker) else { return nil }
        let rest = path[r.upperBound...]
        let dir = rest.split(separator: "/").first.map(String.init) ?? ""
        return dir.isEmpty ? nil : dir
    }
}
