import XCTest
@testable import BuddyCore

final class InstallLocationTests: XCTestCase {
    private let folders = ["/Applications", "/Users/anna/Applications"]

    func testKnowsWhenBuddyIsInAnApplicationsFolder() {
        XCTAssertTrue(InstallLocation.isInstalled("/Applications/Buddy.app", applicationsFolders: folders))
        XCTAssertTrue(InstallLocation.isInstalled("/Applications/Verktyg/Buddy.app", applicationsFolders: folders))
        XCTAssertTrue(InstallLocation.isInstalled("/Users/anna/Applications/Buddy 3.app", applicationsFolders: folders))
        XCTAssertTrue(InstallLocation.isInstalled("/Volumes/Data/Applications/Buddy.app", applicationsFolders: folders),
                      "any folder named Applications")
        XCTAssertTrue(InstallLocation.isInstalled("/tmp/e2e/Program/Buddy.app", applicationsFolders: ["/tmp/e2e/Program/"]))
    }

    func testDownloadsAndTranslocatedCopiesAreNotInstalled() {
        XCTAssertFalse(InstallLocation.isInstalled("/Users/anna/Downloads/Buddy 3.app", applicationsFolders: folders))
        XCTAssertFalse(InstallLocation.isInstalled(
            "/private/var/folders/x1/abc/T/AppTranslocation/1234-5678/d/Buddy.app", applicationsFolders: folders))
        XCTAssertFalse(InstallLocation.isInstalled("/Applicationsfoo/Buddy.app", applicationsFolders: folders))
        XCTAssertFalse(InstallLocation.isInstalled("/Applications", applicationsFolders: folders),
                       "the folder itself is not an app inside it")
        XCTAssertFalse(InstallLocation.isInstalled("/Users/anna/Desktop/Buddy.app", applicationsFolders: []))
    }

    func testInstallsAsBuddyUnlessAnotherAppHasTheName() {
        let ours = "io.github.pal.buddy"
        XCTAssertEqual(InstallLocation.destinationName(ourID: ours) { _ in nil }, "Buddy.app")
        XCTAssertEqual(InstallLocation.destinationName(ourID: ours) { _ in ours }, "Buddy.app", "an older Buddy is replaced")
        let other: (String) -> String? = { $0 == "Buddy.app" ? "com.example.buddy" : nil }
        XCTAssertEqual(InstallLocation.destinationName(ourID: ours, bundleID: other), "Presentation Buddy.app")
        let unreadable: (String) -> String? = { $0 == "Buddy.app" ? "" : ours }
        XCTAssertEqual(InstallLocation.destinationName(ourID: ours, bundleID: unreadable), "Presentation Buddy.app")
        XCTAssertNil(InstallLocation.destinationName(ourID: ours) { _ in "com.example.other" })
    }

    func testReplacesOlderOrSameVersionsAndOpensNewerOnes() {
        XCTAssertEqual(InstallLocation.plan(current: "0.1.3", installedVersion: nil), .install(replacing: nil))
        XCTAssertEqual(InstallLocation.plan(current: "0.1.3", installedVersion: "0.1.1"), .install(replacing: "0.1.1"))
        XCTAssertEqual(InstallLocation.plan(current: "0.1.3", installedVersion: "0.1.3"), .install(replacing: "0.1.3"))
        XCTAssertEqual(InstallLocation.plan(current: "0.1.3", installedVersion: ""), .install(replacing: ""))
        XCTAssertEqual(InstallLocation.plan(current: "0.1.3", installedVersion: "0.1.10"), .openInstalled(version: "0.1.10"))
        XCTAssertEqual(InstallLocation.plan(current: "0.1.3", installedVersion: "v99.0.0"), .openInstalled(version: "99.0.0"))
    }

    func testPromptTexts() {
        let fresh = MovePrompt.make(plan: .install(replacing: nil), current: "0.1.3", folder: "mappen Program",
                                    othersRunning: false, trashesThisCopy: true)
        XCTAssertEqual(fresh.title, "Flytta Buddy till mappen Program?")
        XCTAssertEqual(fresh.message,
                       "Buddy ligger inte i mappen Program. Där heter appen bara Buddy och kan uppdatera sig själv. Den här kopian läggs i papperskorgen.")
        XCTAssertEqual(fresh.confirm, "Flytta till Program")
        XCTAssertEqual(fresh.cancel, "Inte nu")

        let replacing = MovePrompt.make(plan: .install(replacing: "0.1.1"), current: "0.1.3", folder: "mappen Program",
                                        othersRunning: true, trashesThisCopy: false)
        XCTAssertTrue(replacing.message.contains("Version 0.1.1 som redan finns där ersätts."))
        XCTAssertTrue(replacing.message.contains("Buddy som är igång avslutas först."))
        XCTAssertFalse(replacing.message.contains("papperskorgen"))
        let unknown = MovePrompt.make(plan: .install(replacing: ""), current: "0.1.3", folder: "mappen Program",
                                      othersRunning: false, trashesThisCopy: false)
        XCTAssertTrue(unknown.message.hasSuffix("Den Buddy som redan finns där ersätts."))

        let newer = MovePrompt.make(plan: .openInstalled(version: "0.2.0"), current: "0.1.3", folder: "mappen Program",
                                    othersRunning: true, trashesThisCopy: true)
        XCTAssertEqual(newer.title, "Det finns en nyare Buddy i mappen Program")
        XCTAssertEqual(newer.message,
                       "Version 0.2.0 finns redan i mappen Program. Den här kopian är version 0.1.3. Den här kopian läggs i papperskorgen.")
        XCTAssertEqual(newer.confirm, "Öppna Buddy i Program")
        XCTAssertEqual(newer.cancel, "Fortsätt med den här")
    }
}
