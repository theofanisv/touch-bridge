/// Decides whether a one-finger pan that starts at a point should move the window, from what the
/// Accessibility API reports there. Rules come from probing real apps on this Mac (`--ax-probe`):
/// toolbars, plain title bars and title text move the window; text fields, tabs and value controls
/// keep their own drag behaviour; where Accessibility can't tell, the original 28 pt rule applies.
public enum WindowDragRules {
    /// The original fixed title-bar height, used when Accessibility gives no usable answer.
    public static let fallbackTitleBarHeight = 28.0
    /// How far below the window's top edge title text can still be part of the title bar.
    static let titleTextBand = 60.0

    /// Roles whose own drag behaviour must win (selecting text, dragging a URL or tab, moving a value).
    static let ownDragRoles: Set<String> = [
        "TextField", "TextArea", "ComboBox", "Slider", "Incrementor", "ScrollBar", "Splitter",
        "Cell", "Row", "Outline", "Table", "List",
    ]
    static let ownDragSubroles: Set<String> = ["SearchField", "TabButton"]
    /// Roles that carry no interaction of their own (backgrounds, containers, labels).
    static let passiveRoles: Set<String> = ["Window", "Group", "WebArea", "ScrollArea", "StaticText", "Image", "SplitGroup", "Unknown"]

    /// - Parameters:
    ///   - chain: "Role" or "Role/Subrole" (without the "AX" prefix) from the element under the
    ///     finger up to its window; empty when Accessibility gave no answer.
    ///   - offset: points between the window's top edge and the touch.
    public static func isDragArea(chain: [String], offset: Double) -> Bool {
        guard let first = chain.first else { return offset < fallbackTitleBarHeight }
        let (role, subrole) = split(first)
        if ownDragRoles.contains(role) || subrole.map(ownDragSubroles.contains) == true { return false }
        if role == "Window" { return true }
        if chain.contains(where: { split($0).role == "Toolbar" }) { return true }
        if role == "StaticText" || role == "Image", chain.count > 1, split(chain[1]).role == "Window", offset < titleTextBand { return true }
        return passiveRoles.contains(role) && offset < fallbackTitleBarHeight
    }

    private static func split(_ entry: String) -> (role: String, subrole: String?) {
        let parts = entry.split(separator: "/", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }
}
