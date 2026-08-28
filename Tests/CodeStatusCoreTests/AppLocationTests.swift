import Testing
import Foundation
@testable import CodeStatusCore

private let home = URL(fileURLWithPath: "/Users/someone")

private func placement(_ path: String) -> AppLocation.Placement {
    AppLocation.placement(of: URL(fileURLWithPath: path), home: home)
}

@Test("An app in /Applications is where it belongs")
func applicationsIsSettled() {
    #expect(placement("/Applications/CodeStatus.app") == .applications)
    #expect(AppLocation.isSettled(.applications))
}

@Test("~/Applications is a deliberate choice, not a mistake")
func userApplicationsIsSettled() {
    #expect(placement("/Users/someone/Applications/CodeStatus.app") == .userApplications)
    #expect(AppLocation.isSettled(.userApplications))
}

/// The case that matters: opened straight from the downloaded disk image.
///
/// Gatekeeper runs it from a randomised read-only mirror, so updates cannot
/// install, and a login item registered here names a directory that will not
/// exist next time. Both fail silently while the hooks keep working, which is
/// what makes it so hard to notice.
@Test("A translocated bundle is never settled")
func translocationIsDetected() {
    let path = "/private/var/folders/xy/AppTranslocation/A1B2-C3D4/d/CodeStatus.app"
    #expect(placement(path) == .translocated)
    #expect(!AppLocation.isSettled(.translocated))
    #expect(AppLocation.isTranslocated(URL(fileURLWithPath: path)))
}

@Test("Translocation is checked before the folder is")
func translocationOutranksFolder() {
    // A mirror can sit under a path whose last component looks ordinary; the
    // read-only mirror is the fact that matters, not where it appears to be.
    let path = "/private/var/folders/x/AppTranslocation/d/Applications/CodeStatus.app"
    #expect(placement(path) == .translocated)
}

@Test("Downloads and the Desktop are not settled")
func loosePlacementsAreNotSettled() {
    #expect(placement("/Users/someone/Downloads/CodeStatus.app") == .elsewhere)
    #expect(placement("/Users/someone/Desktop/CodeStatus.app") == .elsewhere)
    #expect(placement("/Volumes/CodeStatus/CodeStatus.app") == .elsewhere)
    #expect(!AppLocation.isSettled(.elsewhere))
}

/// A `swift run` build is an executable, not a bundle, and must never be
/// offered a move to Applications — the prompt would be nonsense and the copy
/// would not work.
@Test("A development build is left alone")
func developmentBuildIsNotABundle() {
    #expect(placement("/Users/someone/code/.build/debug/CodeStatusApp") == .notABundle)
    #expect(AppLocation.isSettled(.notABundle), "nothing to fix, so nothing to ask")
}

@Test("A path spelled awkwardly still names the folder it is in")
func pathsAreStandardized() {
    #expect(placement("/Applications/./CodeStatus.app") == .applications)
    #expect(placement("/Applications/Utilities/../CodeStatus.app") == .applications)
}

@Test("Another user's Applications folder is not this user's")
func homeIsNotGuessed() {
    #expect(placement("/Users/someone-else/Applications/CodeStatus.app") == .elsewhere)
}
