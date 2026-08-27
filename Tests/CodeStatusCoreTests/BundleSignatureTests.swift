import Testing
import Foundation
@testable import CodeStatusCore

/// Tests for the one check standing between a download and code running as the
/// user.
///
/// These operate on a real signed bundle rather than a fixture, because what is
/// being tested is the system's own evaluation, not our arithmetic. The bundle
/// is built here rather than taken from `dist/`: a test that quietly does
/// nothing when the app has not been built yet is worse than no test, and this
/// one has to be trustworthy above all the others.
@Suite("Downloaded bundle verification")
struct BundleSignatureTests {

    /// A throwaway `.app` with a nested helper, ad-hoc signed so there is a
    /// valid signature to tamper with.
    ///
    /// Ad-hoc is the right choice here: every assertion is about *validity* or
    /// about anchoring, and no ad-hoc bundle can satisfy a Developer ID
    /// requirement — which is itself one of the things being asserted.
    private struct SignedBundle {
        let url: URL
        let helper: URL
        private let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("codestatus-sig-\(UUID().uuidString)")
            url = root.appendingPathComponent("Probe.app")
            helper = url.appendingPathComponent("Contents/Helpers/nested-helper")

            let macos = url.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: helper.deletingLastPathComponent(), withIntermediateDirectories: true
            )

            // Any Mach-O will do; these are only ever signed and inspected.
            let stub = URL(fileURLWithPath: "/bin/echo")
            try FileManager.default.copyItem(at: stub, to: macos.appendingPathComponent("Probe"))
            try FileManager.default.copyItem(at: stub, to: helper)

            try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>CFBundleIdentifier</key><string>co.codestatus.probe</string>
              <key>CFBundleExecutable</key><string>Probe</string>
              <key>CFBundlePackageType</key><string>APPL</string>
              <key>CFBundleShortVersionString</key><string>1.0.0</string>
            </dict></plist>
            """.utf8).write(to: url.appendingPathComponent("Contents/Info.plist"))

            try #require(
                Self.codesign(["--force", "--deep", "--sign", "-", url.path]),
                "the test fixture itself must sign, or nothing below means anything"
            )
        }

        func destroy() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        static func codesign(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            process.standardError = Pipe()
            process.standardOutput = Pipe()
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    /// Syntactically valid, and matching nothing: the point is that an ad-hoc
    /// signature satisfies no Developer ID requirement at all.
    private let someTeam = "ABCDE12345"

    @Test("A team identifier that could alter the requirement expression is refused")
    func rejectsInjectableTeamIdentifier() throws {
        let bundle = URL(fileURLWithPath: "/Applications")
        for hostile in ["", "AB\"", "A B", "*", "ABCDE12345\" or anchor apple", "AB-CD"] {
            #expect(throws: BundleSignature.Failure.self) {
                try BundleSignature.verify(bundleAt: bundle, isSignedBy: hostile)
            }
        }
    }

    @Test("A path with no bundle at all fails rather than passing vacuously")
    func rejectsMissingBundle() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).app")
        #expect(throws: BundleSignature.Failure.self) {
            try BundleSignature.verify(bundleAt: missing, isSignedBy: someTeam)
        }
    }

    @Test("An ad-hoc signature never satisfies a Developer ID requirement")
    func adHocIsNotDeveloperID() throws {
        let bundle = try SignedBundle()
        defer { bundle.destroy() }

        // Internally valid, anchored to nothing — the shape an attacker's own
        // rebuild of the app would have.
        #expect(verifiesAgainstItself(bundle.url), "the fixture should be internally valid")
        #expect(throws: BundleSignature.Failure.self) {
            try BundleSignature.verify(bundleAt: bundle.url, isSignedBy: someTeam)
        }
    }

    /// The assertion `kSecCSCheckNestedCode` exists for. Without that flag the
    /// outer app validates while a tampered `Contents/Helpers/codestatus-hook` —
    /// the binary every agent on this machine runs on every tool call — passes
    /// straight through.
    @Test("Tampering with a nested helper invalidates the bundle")
    func detectsTamperedHelper() throws {
        let bundle = try SignedBundle()
        defer { bundle.destroy() }
        #expect(verifiesAgainstItself(bundle.url), "valid before tampering")

        var bytes = try Data(contentsOf: bundle.helper)
        // Flipped well inside the executable rather than appended, which some
        // signature formats tolerate as trailing slack.
        let target = bytes.count / 2
        bytes[target] ^= 0xFF
        try bytes.write(to: bundle.helper)

        #expect(!verifiesAgainstItself(bundle.url),
                "a modified helper must invalidate the bundle")
    }

    /// Validity without the Developer ID requirement, which is what separates
    /// "was it tampered with" from "is it ours".
    private func verifiesAgainstItself(_ url: URL) -> Bool {
        SignedBundle.codesign(["--verify", "--deep", "--strict", url.path])
    }
}
