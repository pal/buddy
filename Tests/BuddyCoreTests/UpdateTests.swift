import XCTest
@testable import BuddyCore

final class UpdateTests: XCTestCase {
    func testVersionsCompareNumerically() throws {
        let v = { (text: String) in try XCTUnwrap(AppVersion(text)) }
        XCTAssertLessThan(try v("0.1.9"), try v("0.1.10"))
        XCTAssertLessThan(try v("v0.1.1"), try v("0.2.0"))
        XCTAssertLessThan(try v("0.9.9"), try v("1.0"))
        XCTAssertEqual(try v("1.0"), try v("1.0.0"))
        XCTAssertFalse(try v("1.2.3") < v("1.2.3"))
        XCTAssertEqual(try v("v2.10.0").description, "2.10.0")
    }

    func testRejectsAnythingButPlainVersions() {
        XCTAssertNil(AppVersion("1.0.0-beta"))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("1.2.3.4.5"))
    }

    func testParsesTheLatestReleaseAndPicksTheZip() throws {
        let data = Data("""
        {"tag_name": "v0.1.2", "name": "Buddy 0.1.2", "html_url": "https://github.com/pal/buddy/releases/tag/v0.1.2",
         "draft": false, "prerelease": false,
         "assets": [
           {"name": "Buddy.dmg", "browser_download_url": "https://github.com/pal/buddy/releases/download/v0.1.2/Buddy.dmg"},
           {"name": "Buddy.zip", "browser_download_url": "https://github.com/pal/buddy/releases/download/v0.1.2/Buddy.zip"}
         ]}
        """.utf8)
        let release = try ReleaseInfo.parse(data)
        XCTAssertEqual(release.version.description, "0.1.2")
        XCTAssertEqual(release.archiveURL.absoluteString, "https://github.com/pal/buddy/releases/download/v0.1.2/Buddy.zip")
        XCTAssertEqual(release.pageURL?.absoluteString, "https://github.com/pal/buddy/releases/tag/v0.1.2")
    }

    func testRefusesReleasesItCannotInstall() {
        func parse(_ json: String) -> ReleaseInfo.ParseError? {
            do {
                _ = try ReleaseInfo.parse(Data(json.utf8))
                return nil
            } catch {
                return error as? ReleaseInfo.ParseError
            }
        }
        XCTAssertEqual(parse("not json"), .invalidJSON)
        XCTAssertEqual(parse(#"{"tag_name": "nightly", "assets": []}"#), .notAVersion("nightly"))
        XCTAssertEqual(parse(#"{"tag_name": "v1.0.0", "assets": []}"#), .noArchive)
        XCTAssertEqual(parse(#"{"tag_name": "v1.0.0", "prerelease": true, "assets": []}"#), .draftOrPrerelease)
        XCTAssertEqual(parse(#"{"tag_name": "v1.0.0", "assets": [{"name": "Buddy.zip", "browser_download_url": "http://example.com/Buddy.zip"}]}"#),
                       .noArchive, "only https downloads")
    }

    func testChecksOncePerDay() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdatePolicy.isCheckDue(now: now, lastCheck: nil))
        XCTAssertFalse(UpdatePolicy.isCheckDue(now: now, lastCheck: now.addingTimeInterval(-3600)))
        XCTAssertTrue(UpdatePolicy.isCheckDue(now: now, lastCheck: now.addingTimeInterval(-25 * 3600)))
        XCTAssertTrue(UpdatePolicy.isCheckDue(now: now, lastCheck: now.addingTimeInterval(3600)), "a clock that went backwards")
    }

    func testInstallsOnlyWhenIdleAndNotBusy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(UpdatePolicy.canInstallNow(now: now, lastActivity: now.addingTimeInterval(-60), busy: false))
        XCTAssertTrue(UpdatePolicy.canInstallNow(now: now, lastActivity: now.addingTimeInterval(-21 * 60), busy: false))
        XCTAssertFalse(UpdatePolicy.canInstallNow(now: now, lastActivity: now.addingTimeInterval(-3600), busy: true))
    }
}
