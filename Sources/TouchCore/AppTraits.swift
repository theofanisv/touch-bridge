/// Facts about an app that change how touches must be delivered to it.
public enum AppTraits {
    private static let chromiumMarkers = ["Electron", "Chromium", "Chrome", "Edge", "Brave", "Vivaldi", "Opera"]

    /// Chromium/Electron apps ship a "<Name> Framework.framework" in Contents/Frameworks.
    public static func isChromiumFramework(named name: String) -> Bool {
        name.hasSuffix(" Framework.framework") && chromiumMarkers.contains { name.contains($0) }
    }
}
