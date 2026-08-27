import Foundation
import Security

/// Decides whether a downloaded bundle is genuinely ours before anything is
/// allowed to replace the running app with it.
///
/// This is the security boundary of the whole updater. Everything upstream —
/// HTTPS, the GitHub API, the release workflow — is a convenience; this check is
/// the part that has to hold even if all of it is lying. A bundle that fails
/// here is deleted, never executed.
///
/// Uses the system's own code-signing evaluation rather than parsing `codesign`
/// output, because the failure mode of a text parser here is "accepts something
/// it should have rejected".
public enum BundleSignature {

    public enum Failure: Error, CustomStringConvertible {
        case unsigned
        case unusableTeamIdentifier(String)
        case cannotRead(OSStatus)
        case rejected(OSStatus, String?)

        public var description: String {
            switch self {
            case .unsigned:
                return "this build is not Developer ID signed"
            case .unusableTeamIdentifier(let id):
                return "unusable team identifier '\(id)'"
            case .cannotRead(let status):
                return "could not read the downloaded signature (OSStatus \(status))"
            case .rejected(let status, let detail):
                return detail.map { "signature rejected: \($0)" }
                    ?? "signature rejected (OSStatus \(status))"
            }
        }
    }

    /// The team the *running* app is signed by.
    ///
    /// Read at runtime rather than compiled in, so there is one fewer constant
    /// to get wrong, and so an ad-hoc signed local build reports no team and
    /// disables updating altogether — which is the behaviour we want: a
    /// development build must never replace itself from the internet.
    public static func runningTeamIdentifier() throws -> String {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else { throw Failure.cannotRead(status) }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw Failure.cannotRead(status) }

        var information: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        )
        guard status == errSecSuccess,
              let details = information as? [String: Any],
              let team = details[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            throw Failure.unsigned
        }
        return team
    }

    /// Verifies a bundle on disk against a Developer ID team.
    ///
    /// `kSecCSCheckNestedCode` is the flag that matters: without it the outer
    /// app validates while a tampered `Contents/Helpers/codestatus-hook` — the
    /// binary every agent on this machine executes on every tool call — sails
    /// through. Slower, and not optional.
    public static func verify(bundleAt url: URL, isSignedBy team: String) throws {
        // The team goes into a requirement expression, so it must not be able to
        // carry quotes or operators. Apple team identifiers are alphanumeric.
        guard !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw Failure.unusableTeamIdentifier(team)
        }

        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else { throw Failure.cannotRead(status) }

        // "anchor apple generic" pins the chain to Apple's roots, so a bundle
        // signed by a self-made CA that happens to put the same string in the
        // OU field cannot satisfy this.
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw Failure.cannotRead(status) }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate)
        var errors: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &errors)
        guard status == errSecSuccess else {
            let detail = errors?.takeRetainedValue().localizedDescription
            throw Failure.rejected(status, detail)
        }
    }
}
