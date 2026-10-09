import Testing
@testable import TouchCore

// Role chains (element first, up to the window) as reported by the Accessibility API on this Mac,
// captured with `TouchBridge --ax-probe` on 2026-10-09. `offset` is points below the window's top edge.

@Test func safarisEmptyToolbarMovesTheWindow() {
    #expect(WindowDragRules.isDragArea(chain: ["Group", "Toolbar", "Window/StandardWindow"], offset: 4))
    #expect(WindowDragRules.isDragArea(chain: ["Toolbar", "Window/StandardWindow"], offset: 38))
}

@Test func panningFromAToolbarButtonMovesTheWindow() {
    // A tap on the button still clicks it; only a pan that starts there moves the window.
    #expect(WindowDragRules.isDragArea(chain: ["Button/Segment", "Group", "Group", "Toolbar", "Window/StandardWindow"], offset: 20))
}

@Test func safarisAddressFieldDoesNotMoveTheWindow() {
    #expect(!WindowDragRules.isDragArea(chain: ["TextField", "Group", "Toolbar", "Window/StandardWindow"], offset: 12))
    #expect(!WindowDragRules.isDragArea(chain: ["TextField/SearchField", "Group/HostingView", "SplitGroup", "Window/StandardWindow"], offset: 20))
}

@Test func tabsDoNotMoveTheWindow() {
    #expect(!WindowDragRules.isDragArea(chain: ["RadioButton/TabButton", "Group", "Window/StandardWindow"], offset: 95))
}

@Test func aPlainTitleBarAndItsTitleTextMoveTheWindow() {
    #expect(WindowDragRules.isDragArea(chain: ["Window/StandardWindow"], offset: 4))
    #expect(WindowDragRules.isDragArea(chain: ["StaticText", "Window/StandardWindow"], offset: 12))
}

@Test func textDirectlyInTheWindowBelowTheTitleBandDoesNotMoveIt() {
    #expect(!WindowDragRules.isDragArea(chain: ["StaticText", "Window/StandardWindow"], offset: 300))
}

@Test func whenAccessibilityCannotTellTheTop28PointsStillMoveTheWindow() {
    // Electron apps draw their own title bar as web content.
    let electron = ["WebArea", "ScrollArea", "Group", "Group", "Group", "Group"]
    #expect(WindowDragRules.isDragArea(chain: electron, offset: 10))
    #expect(!WindowDragRules.isDragArea(chain: electron, offset: 45))
    #expect(!WindowDragRules.isDragArea(chain: electron, offset: 300))
}

@Test func controlsOutsideAToolbarDoNotMoveTheWindow() {
    #expect(!WindowDragRules.isDragArea(chain: ["CheckBox/ToggleButton", "Group", "Group", "Group", "Group", "Group"], offset: 20))
}

@Test func withoutAccessibilityTheOld28PointRuleApplies() {
    #expect(WindowDragRules.isDragArea(chain: [], offset: 27))
    #expect(!WindowDragRules.isDragArea(chain: [], offset: 28))
}
