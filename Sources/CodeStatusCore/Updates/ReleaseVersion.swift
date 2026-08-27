import Foundation

/// A released version, ordered so "is this newer than what I am running" has one
/// answer.
///
/// Deliberately not a general semver implementation: this only ever compares
/// versions this project produced, which are `MAJOR.MINOR.PATCH` with an
/// optional `v` prefix on the tag. Anything else fails to parse rather than
/// being coerced into a number, because a version we cannot read is a version we
/// must not decide to install.
public struct ReleaseVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `1.2.3`, `v1.2.3`, and the two-component `1.2` that a hand-typed
    /// tag sometimes carries. Returns `nil` for everything else.
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.first == "v" || body.first == "V" { body.removeFirst() }
        guard !body.isEmpty else { return nil }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }

        var numbers: [Int] = []
        for part in parts {
            // `Int(_:)` accepts a leading "+" and "-"; a version component that
            // is signed is malformed, not negative.
            guard part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        major = numbers[0]
        minor = numbers[1]
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}
