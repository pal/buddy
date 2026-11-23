import Foundation

/// A version number such as "0.1.2" (a leading "v" is allowed).
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    /// nil for anything but dot-separated numbers, so pre-releases ("1.0.0-beta") are never installed.
    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCIIDigit), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        for index in 0..<count {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// The newest release, from GitHub's "latest release" API.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: AppVersion
    public let tag: String
    public let archiveURL: URL
    public let pageURL: URL?

    public enum ParseError: Error, Equatable {
        case invalidJSON
        case notAVersion(String)
        case noArchive
        case draftOrPrerelease
    }

    private struct Response: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    public static func parse(_ data: Data, archiveName: String = "Buddy.zip") throws -> ReleaseInfo {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw ParseError.invalidJSON }
        if response.draft == true || response.prerelease == true { throw ParseError.draftOrPrerelease }
        guard let version = AppVersion(response.tag_name) else { throw ParseError.notAVersion(response.tag_name) }
        guard let asset = response.assets.first(where: { $0.name == archiveName }),
              let url = URL(string: asset.browser_download_url), url.scheme == "https" || url.host == "127.0.0.1"
        else { throw ParseError.noArchive }
        return ReleaseInfo(version: version, tag: response.tag_name, archiveURL: url, pageURL: response.html_url.flatMap(URL.init(string:)))
    }

    /// The latest release from GitHub's web page instead of the API, which allows only 60
    /// requests an hour per network address without credentials. `https://github.com/OWNER/REPO/releases/latest`
    /// redirects to `…/releases/tag/vX.Y.Z`, and the archive is at `…/releases/download/vX.Y.Z/Buddy.zip`.
    /// - latestPage: the `…/releases/latest` address that was requested.
    /// - finalURL: where the redirects ended.
    public static func fromReleasePage(latestPage: URL, finalURL: URL, archiveName: String = "Buddy.zip") throws -> ReleaseInfo {
        let parts = finalURL.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[parts.count - 2] == "tag", let tag = parts.last?.removingPercentEncoding, !tag.isEmpty else {
            throw ParseError.notAVersion(finalURL.absoluteString)
        }
        // A tag that is a version has only digits, dots and a leading "v": safe in a path.
        guard let version = AppVersion(tag) else { throw ParseError.notAVersion(tag) }
        guard latestPage.scheme == "https" || latestPage.host == "127.0.0.1" else { throw ParseError.noArchive }
        let archive = latestPage.deletingLastPathComponent()
            .appendingPathComponent("download")
            .appendingPathComponent(tag, isDirectory: true)
            .appendingPathComponent(archiveName)
        return ReleaseInfo(version: version, tag: tag, archiveURL: archive, pageURL: finalURL)
    }
}

/// When to look for and install updates.
public enum UpdatePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    /// Buddy must have been unused this long before it restarts itself with a new version.
    public static let idleBeforeInstall: TimeInterval = 20 * 60

    public static func isCheckDue(now: Date, lastCheck: Date?, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || lastCheck > now
    }

    /// Never in the middle of a dialog or while a window is open, and only after a quiet spell,
    /// so Buddy does not restart during a presentation.
    public static func canInstallNow(now: Date, lastActivity: Date, busy: Bool, idle: TimeInterval = idleBeforeInstall) -> Bool {
        !busy && now.timeIntervalSince(lastActivity) >= idle
    }
}
