import Testing
@testable import TouchCore

@Test func recognizesChromiumAndElectronFrameworkBundles() {
    for name in ["Electron Framework.framework", "Chromium Embedded Framework.framework", "Google Chrome Framework.framework",
                 "Microsoft Edge Framework.framework", "Brave Browser Framework.framework"] {
        #expect(AppTraits.isChromiumFramework(named: name), "\(name)")
    }
}

@Test func ignoresOrdinaryFrameworks() {
    for name in ["Sparkle.framework", "Squirrel.framework", "Mantle.framework", "Chrome.txt"] {
        #expect(!AppTraits.isChromiumFramework(named: name), "\(name)")
    }
}
