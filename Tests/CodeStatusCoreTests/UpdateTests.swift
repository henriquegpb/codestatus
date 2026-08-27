import Testing
import Foundation
@testable import CodeStatusCore

@Suite("Release versions")
struct ReleaseVersionTests {

    @Test("Reads the shapes our own tags and bundles use", arguments: [
        ("0.3.0", ReleaseVersion(major: 0, minor: 3, patch: 0)),
        ("v0.3.0", ReleaseVersion(major: 0, minor: 3, patch: 0)),
        ("1.2.3", ReleaseVersion(major: 1, minor: 2, patch: 3)),
        // A two-component tag is a hand-typed one; the missing patch is zero.
        ("2.1", ReleaseVersion(major: 2, minor: 1, patch: 0)),
        ("  v10.20.30 ", ReleaseVersion(major: 10, minor: 20, patch: 30)),
    ])
    func parses(text: String, expected: ReleaseVersion) {
        #expect(ReleaseVersion(text) == expected)
    }

    /// A version we cannot read must not become a version we can compare, since
    /// the comparison is what decides whether to replace the app on disk.
    @Test("Refuses anything it cannot read exactly", arguments: [
        "", "v", "1", "1.2.3.4", "1.x.0", "one.two.three", "1.-2.0", "1.+2.0",
        "0.3.0-beta", "latest", "1..0",
    ])
    func rejects(text: String) {
        #expect(ReleaseVersion(text) == nil, "should not have parsed '\(text)'")
    }

    @Test("Orders by major, then minor, then patch")
    func orders() {
        #expect(ReleaseVersion("0.2.0")! < ReleaseVersion("0.3.0")!)
        #expect(ReleaseVersion("0.9.9")! < ReleaseVersion("1.0.0")!)
        #expect(ReleaseVersion("1.0.1")! > ReleaseVersion("1.0.0")!)
        #expect(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.0")!, "not compared as text")
        #expect(ReleaseVersion("1.0.0")! == ReleaseVersion("v1.0.0")!)
    }
}

@Suite("Release feed")
struct ReleaseFeedTests {

    /// Trimmed from a real `/releases/latest` response — the fields we read,
    /// with one we do not, so the decoder is exercised as the tolerant reader it
    /// is meant to be rather than a strict schema.
    private func payload(
        tag: String = "v0.3.0",
        assetName: String = "CodeStatus.zip",
        url: String = "https://github.com/henriquegpb/codestatus/releases/download/v0.3.0/CodeStatus.zip",
        extra: String = ""
    ) -> Data {
        Data("""
        {"tag_name":"\(tag)","name":"\(tag)","draft":false,"prerelease":false,\(extra)
         "author":{"login":"henriquegpb","id":1},
         "assets":[
           {"name":"CodeStatus-0.3.0.dmg","browser_download_url":"https://example.invalid/a.dmg"},
           {"name":"\(assetName)","browser_download_url":"\(url)","size":900000}
         ]}
        """.utf8)
    }

    @Test("Reads the version and the archive out of a real payload")
    func decodes() throws {
        let release = try ReleaseFeed.decodeLatest(payload())
        #expect(release.version == ReleaseVersion(major: 0, minor: 3, patch: 0))
        #expect(release.archiveURL.lastPathComponent == "CodeStatus.zip")
    }

    @Test("Refuses a download that is not over HTTPS")
    func requiresHTTPS() {
        #expect(throws: ReleaseFeed.DecodeError.noArchiveAsset("CodeStatus.zip")) {
            try ReleaseFeed.decodeLatest(payload(url: "http://example.invalid/CodeStatus.zip"))
        }
    }

    @Test("Refuses a release with no archive for the updater")
    func requiresTheAsset() {
        #expect(throws: ReleaseFeed.DecodeError.noArchiveAsset("CodeStatus.zip")) {
            try ReleaseFeed.decodeLatest(payload(assetName: "SomethingElse.zip"))
        }
    }

    @Test("Refuses a tag it cannot turn into a version")
    func requiresAReadableTag() {
        #expect(throws: ReleaseFeed.DecodeError.unreadableTag) {
            try ReleaseFeed.decodeLatest(payload(tag: "nightly"))
        }
    }

    @Test("Refuses a build that was not meant to be public")
    func refusesDrafts() {
        #expect(throws: ReleaseFeed.DecodeError.draftOrPrerelease) {
            try ReleaseFeed.decodeLatest(Data("""
            {"tag_name":"v9.0.0","draft":true,"assets":[]}
            """.utf8))
        }
        #expect(throws: ReleaseFeed.DecodeError.draftOrPrerelease) {
            try ReleaseFeed.decodeLatest(Data("""
            {"tag_name":"v9.0.0","prerelease":true,"assets":[]}
            """.utf8))
        }
    }

    @Test("Garbage on the wire is an error, not a crash")
    func refusesGarbage() {
        #expect(throws: ReleaseFeed.DecodeError.notJSON) {
            try ReleaseFeed.decodeLatest(Data("<html>rate limited</html>".utf8))
        }
    }
}

@Suite("Update policy")
struct UpdatePolicyTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Checks on first run, then once a day")
    func checkInterval() {
        #expect(UpdatePolicy.shouldCheck(now: t0, lastCheckedAt: nil))
        #expect(!UpdatePolicy.shouldCheck(now: t0.addingTimeInterval(3600), lastCheckedAt: t0))
        #expect(UpdatePolicy.shouldCheck(now: t0.addingTimeInterval(86_400), lastCheckedAt: t0))
    }

    /// A restored backup or a timezone correction can put the stored date in the
    /// future. Parking updates until the clock catches up would strand a machine
    /// on an old build for as long as the skew lasts.
    @Test("A clock that moved backwards does not park updates")
    func toleratesClockSkew() {
        #expect(UpdatePolicy.shouldCheck(now: t0, lastCheckedAt: t0.addingTimeInterval(86_400)))
    }

    @Test("Only a strictly newer version is an update")
    func onlyUpgrades() {
        let current = ReleaseVersion("0.3.0")!
        #expect(UpdatePolicy.isUpgrade(from: current, to: ReleaseVersion("0.3.1")!))
        #expect(!UpdatePolicy.isUpgrade(from: current, to: current))
        // A lower version is a yanked release or someone answering our request
        // for us. Neither is something to install unattended.
        #expect(!UpdatePolicy.isUpgrade(from: current, to: ReleaseVersion("0.2.9")!))
    }

    @Test("Installs only when nothing is running")
    func waitsForQuiet() {
        #expect(UpdatePolicy.holdReason(
            hasActiveSessions: false, bundleIsReplaceable: true
        ) == nil)
        #expect(UpdatePolicy.holdReason(
            hasActiveSessions: true, bundleIsReplaceable: true
        ) == .sessionsAreActive)
    }

    /// Where the app lives is checked first: an installation that can never be
    /// replaced should say so rather than reporting itself as merely busy, which
    /// reads as "it will happen later" and never does.
    @Test("An unreplaceable install reports that, not busyness")
    func immovabilityWins() {
        #expect(UpdatePolicy.holdReason(
            hasActiveSessions: true, bundleIsReplaceable: false
        ) == .bundleNotReplaceable)
    }
}
