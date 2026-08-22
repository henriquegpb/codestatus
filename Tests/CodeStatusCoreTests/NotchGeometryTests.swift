import Testing
import CoreGraphics
@testable import CodeStatusCore

// MARK: - Fixtures

/// 14" MacBook Pro: 1512x982 points, a 32pt safe-area inset, and a ~200pt notch
/// centred between two 656pt auxiliary areas (656 + 200 + 656 == 1512).
private let builtIn = ScreenDescription(
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 656, height: 32),
    auxiliaryTopRightArea: CGRect(x: 856, y: 950, width: 656, height: 32),
    backingScaleFactor: 2
)

/// A 27" 2560x1440 external display arranged to the right of the built-in one,
/// at 1x — the scale factor deliberately differs from ``builtIn``.
private let external = ScreenDescription(
    frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
    backingScaleFactor: 1
)

/// A display arranged to the *left* of and lower than the main one, so both
/// origin components are negative.
private let leftOfMain = ScreenDescription(
    frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080),
    backingScaleFactor: 2
)

/// The built-in display arranged to the left of an external main display, so a
/// notch has to be located at a negative x.
private let builtInAtNegativeOrigin = ScreenDescription(
    frame: CGRect(x: -1512, y: 300, width: 1512, height: 982),
    safeAreaTopInset: 32,
    auxiliaryTopLeftArea: CGRect(x: -1512, y: 1250, width: 656, height: 32),
    auxiliaryTopRightArea: CGRect(x: -656, y: 1250, width: 656, height: 32),
    backingScaleFactor: 2
)

private let tiny = ScreenDescription(
    frame: CGRect(x: 0, y: 0, width: 200, height: 150),
    backingScaleFactor: 2
)

private let validFixtures: [ScreenDescription] = [builtIn, external, leftOfMain, builtInAtNegativeOrigin, tiny]

private let pathologicalSizes: [CGSize] = [
    .zero,
    CGSize(width: CGFloat.nan, height: CGFloat.nan),
    CGSize(width: -400, height: -30),
    CGSize(width: CGFloat.infinity, height: CGFloat.infinity),
    CGSize(width: 100_000, height: 100_000),
    CGSize(width: 0.0001, height: 0.0001)
]

private func isFinite(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
}

private func isPixelAligned(_ value: CGFloat, scale: CGFloat) -> Bool {
    (value * scale).truncatingRemainder(dividingBy: 1) == 0
}

// MARK: - Notch detection

@Suite("Notch detection")
struct NotchDetectionTests {

    @Test("A built-in display's notch is exactly the gap between the auxiliary areas")
    func notchIsTheGap() {
        #expect(NotchGeometry.isNotched(builtIn))
        #expect(NotchGeometry.notchRect(for: builtIn) == CGRect(x: 656, y: 950, width: 200, height: 32))
    }

    @Test("A notch is located correctly on a display arranged at a negative origin")
    func notchAtNegativeOrigin() {
        let notch = NotchGeometry.notchRect(for: builtInAtNegativeOrigin)
        #expect(notch == CGRect(x: -856, y: 1250, width: 200, height: 32))
    }

    @Test("An external display with no safe-area inset is not notched")
    func externalIsNotNotched() {
        #expect(NotchGeometry.isNotched(external) == false)
        #expect(NotchGeometry.notchRect(for: external) == nil)
        #expect(NotchGeometry.maximumCompactContentSize(for: external) == nil)
    }

    @Test("A safe-area inset with no auxiliary areas is not enough evidence to place a window over the menu bar")
    func insetAloneIsNotANotch() {
        var screen = builtIn
        screen.auxiliaryTopLeftArea = nil
        screen.auxiliaryTopRightArea = nil
        #expect(NotchGeometry.isNotched(screen) == false)

        var halfReported = builtIn
        halfReported.auxiliaryTopRightArea = nil
        #expect(NotchGeometry.isNotched(halfReported) == false)
    }

    @Test("Auxiliary areas that meet leave no notch")
    func touchingAuxiliaryAreasAreNotANotch() {
        var screen = builtIn
        screen.auxiliaryTopLeftArea = CGRect(x: 0, y: 950, width: 756, height: 32)
        screen.auxiliaryTopRightArea = CGRect(x: 756, y: 950, width: 756, height: 32)
        #expect(NotchGeometry.notchRect(for: screen) == nil)
    }

    @Test("Auxiliary areas belonging to another display are rejected rather than trusted")
    func mismatchedAuxiliaryAreas() {
        var screen = external
        screen.safeAreaTopInset = 32
        screen.auxiliaryTopLeftArea = builtIn.auxiliaryTopLeftArea
        screen.auxiliaryTopRightArea = builtIn.auxiliaryTopRightArea
        #expect(NotchGeometry.notchRect(for: screen) == nil)
    }

    @Test("The menu bar strip is the safe-area inset when there is one and the standard height otherwise")
    func menuBarHeight() {
        #expect(NotchGeometry.menuBarHeight(for: builtIn) == 32)
        #expect(NotchGeometry.menuBarHeight(for: external) == NotchGeometry.standardMenuBarHeight)
    }
}

// MARK: - Compact pill

@Suite("Compact pill placement")
struct CompactHUDTests {

    @Test("The compact pill sits entirely inside the notch")
    func compactIsInsideTheNotch() throws {
        let notch = try #require(NotchGeometry.notchRect(for: builtIn))
        let frame = NotchGeometry.compactHUDFrame(for: builtIn, contentSize: CGSize(width: 120, height: 22))
        #expect(notch.contains(frame))
        #expect(frame.width == 120)
        #expect(frame.height == 22)
    }

    @Test("The compact pill never intersects either auxiliary area, at any content width")
    func compactNeverCoversTheMenuBar() throws {
        let left = try #require(builtIn.auxiliaryTopLeftArea)
        let right = try #require(builtIn.auxiliaryTopRightArea)
        for width in stride(from: CGFloat(0), through: 400, by: 7) {
            for height in [CGFloat(0), 12, 22, 31, 64] {
                let frame = NotchGeometry.compactHUDFrame(
                    for: builtIn,
                    contentSize: CGSize(width: width, height: height)
                )
                #expect(frame.intersects(left) == false, "width \(width) height \(height) hit the left menu bar area")
                #expect(frame.intersects(right) == false, "width \(width) height \(height) hit the right menu bar area")
                #expect(builtIn.frame.contains(frame))
            }
        }
    }

    @Test("Content too wide for the notch is relocated below the menu bar rather than clipped")
    func overWideContentFallsBelowTheMenuBar() {
        let requested = CGSize(width: 400, height: 22)
        let frame = NotchGeometry.compactHUDFrame(for: builtIn, contentSize: requested)
        let fallback = NotchGeometry.nonNotchedHUDFrame(for: builtIn, contentSize: requested)
        #expect(frame == fallback)
        // Nothing was clipped away, and it is clear of the menu bar strip.
        #expect(frame.width == 400)
        #expect(frame.maxY <= builtIn.frame.maxY - NotchGeometry.menuBarHeight(for: builtIn))
    }

    @Test("Content too tall for the notch is relocated below the menu bar as well")
    func overTallContentFallsBelowTheMenuBar() throws {
        let notch = try #require(NotchGeometry.notchRect(for: builtIn))
        let frame = NotchGeometry.compactHUDFrame(for: builtIn, contentSize: CGSize(width: 80, height: 60))
        #expect(notch.contains(frame) == false)
        #expect(frame.maxY <= builtIn.frame.maxY - NotchGeometry.menuBarHeight(for: builtIn))
    }

    @Test("Content sized against the advertised maximum still fits the notch")
    func maximumCompactContentFits() throws {
        let maximum = try #require(NotchGeometry.maximumCompactContentSize(for: builtIn))
        let notch = try #require(NotchGeometry.notchRect(for: builtIn))
        #expect(maximum == CGSize(width: 192, height: 28))
        let frame = NotchGeometry.compactHUDFrame(for: builtIn, contentSize: maximum)
        #expect(notch.contains(frame))
    }

    @Test("A display with no notch gets a floating pill just below the menu bar")
    func nonNotchedPillSitsBelowTheMenuBar() {
        let frame = NotchGeometry.compactHUDFrame(for: external, contentSize: CGSize(width: 160, height: 28))
        #expect(frame == NotchGeometry.nonNotchedHUDFrame(for: external, contentSize: CGSize(width: 160, height: 28)))
        #expect(frame.maxY == external.frame.maxY - NotchGeometry.standardMenuBarHeight - NotchGeometry.menuBarGap)
        #expect(frame.midX == external.frame.midX)
        #expect(frame.size == CGSize(width: 160, height: 28))
        #expect(external.frame.contains(frame))
    }

    @Test("A display at a negative origin keeps its pill inside its own frame")
    func negativeOriginPillStaysHome() throws {
        let notch = try #require(NotchGeometry.notchRect(for: builtInAtNegativeOrigin))
        let compact = NotchGeometry.compactHUDFrame(for: builtInAtNegativeOrigin, contentSize: CGSize(width: 120, height: 22))
        #expect(notch.contains(compact))
        #expect(compact.maxX < 0)

        let floating = NotchGeometry.nonNotchedHUDFrame(for: leftOfMain, contentSize: CGSize(width: 160, height: 28))
        #expect(leftOfMain.frame.contains(floating))
        #expect(floating.midX == leftOfMain.frame.midX)
    }
}

// MARK: - Expanded panel

@Suite("Expanded panel placement")
struct ExpandedHUDTests {

    @Test("The expanded panel stays inside the display on every fixture and every content size")
    func expandedIsAlwaysOnScreen() {
        let sizes = pathologicalSizes + [
            CGSize(width: 420, height: 360),
            CGSize(width: 1200, height: 900),
            CGSize(width: 3000, height: 2000)
        ]
        for screen in validFixtures {
            for size in sizes {
                let frame = NotchGeometry.expandedHUDFrame(for: screen, contentSize: size)
                #expect(isFinite(frame))
                #expect(frame.width > 0 && frame.height > 0)
                #expect(screen.frame.contains(frame), "\(size) escaped \(screen.frame)")
            }
        }
    }

    @Test("The expanded panel hangs from the menu bar's lower edge, centred on the notch")
    func expandedHangsFromTheNotch() throws {
        let notch = try #require(NotchGeometry.notchRect(for: builtIn))
        let frame = NotchGeometry.expandedHUDFrame(for: builtIn, contentSize: CGSize(width: 420, height: 360))
        #expect(frame.maxY == builtIn.frame.maxY - NotchGeometry.menuBarHeight(for: builtIn))
        #expect(frame.midX == notch.midX)
        #expect(frame.size == CGSize(width: 420, height: 360))
        // Growing downward means it never re-enters the menu bar strip.
        #expect(frame.maxY < builtIn.frame.maxY)
    }

    @Test("The expanded panel is centred on the display when there is no notch")
    func expandedCentresOnNonNotchedDisplay() {
        let frame = NotchGeometry.expandedHUDFrame(for: external, contentSize: CGSize(width: 420, height: 360))
        #expect(frame.midX == external.frame.midX)
        #expect(frame.maxY == external.frame.maxY - NotchGeometry.standardMenuBarHeight)
    }

    @Test("A display smaller than the requested panel shrinks it instead of overflowing")
    func smallDisplayShrinksThePanel() {
        let frame = NotchGeometry.expandedHUDFrame(for: tiny, contentSize: CGSize(width: 500, height: 400))
        #expect(tiny.frame.contains(frame))
        #expect(frame.width <= tiny.frame.width)
        #expect(frame.height <= tiny.frame.height - NotchGeometry.standardMenuBarHeight)
        #expect(frame.width > 0 && frame.height > 0)
    }

    @Test("A display too small even for the margins still yields a usable frame")
    func absurdlySmallDisplay() {
        let sliver = ScreenDescription(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        for presentation in HUDPresentation.allCases {
            let frame = NotchGeometry.hudFrame(for: sliver, presentation: presentation, contentSize: CGSize(width: 200, height: 100))
            #expect(isFinite(frame))
            #expect(frame.width > 0 && frame.height > 0)
            #expect(sliver.frame.contains(frame))
        }
    }
}

// MARK: - Robustness

@Suite("HUD geometry robustness")
struct NotchGeometryRobustnessTests {

    @Test("No pathological content size can produce a NaN, infinite, or negative frame")
    func pathologicalSizesStayFinite() {
        for screen in validFixtures {
            for size in pathologicalSizes {
                for presentation in HUDPresentation.allCases {
                    let frame = NotchGeometry.hudFrame(for: screen, presentation: presentation, contentSize: size)
                    #expect(isFinite(frame), "\(size) on \(screen.frame) produced \(frame)")
                    #expect(frame.width >= 0 && frame.height >= 0)
                    #expect(frame.width > 0 && frame.height > 0, "\(size) collapsed to nothing")
                    #expect(screen.frame.contains(frame))
                }
            }
        }
    }

    @Test("A display whose own geometry is not finite yields an empty frame rather than a lost window")
    func nonFiniteScreenYieldsZero() {
        let broken = [
            ScreenDescription(frame: CGRect(x: CGFloat.nan, y: 0, width: 1512, height: 982)),
            ScreenDescription(frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 982)),
            ScreenDescription(frame: .zero),
            ScreenDescription(frame: CGRect(x: 0, y: 0, width: -100, height: -100))
        ]
        for screen in broken {
            for presentation in HUDPresentation.allCases {
                let frame = NotchGeometry.hudFrame(for: screen, presentation: presentation, contentSize: CGSize(width: 120, height: 22))
                #expect(frame == .zero)
            }
        }
    }

    @Test("A negative backing scale factor disables snapping instead of corrupting the frame")
    func invalidScaleFactorIsIgnored() throws {
        var screen = builtIn
        screen.backingScaleFactor = -3
        let notch = try #require(NotchGeometry.notchRect(for: screen))
        let frame = NotchGeometry.compactHUDFrame(for: screen, contentSize: CGSize(width: 121.3, height: 22.7))
        #expect(isFinite(frame))
        #expect(notch.contains(frame))

        screen.backingScaleFactor = CGFloat.nan
        let nanFrame = NotchGeometry.compactHUDFrame(for: screen, contentSize: CGSize(width: 121.3, height: 22.7))
        #expect(isFinite(nanFrame))
        #expect(notch.contains(nanFrame))
    }

    @Test("Frames are snapped to each display's own pixel grid")
    func framesAreSnappedPerDisplay() {
        let retina = NotchGeometry.compactHUDFrame(for: builtIn, contentSize: CGSize(width: 121.3, height: 22.7))
        for value in [retina.minX, retina.minY, retina.width, retina.height] {
            #expect(isPixelAligned(value, scale: 2), "\(retina) is not aligned to a 2x grid")
        }

        let oneX = NotchGeometry.expandedHUDFrame(for: external, contentSize: CGSize(width: 421.4, height: 360.6))
        for value in [oneX.minX, oneX.minY, oneX.width, oneX.height] {
            #expect(isPixelAligned(value, scale: 1), "\(oneX) is not aligned to a 1x grid")
        }
    }

    @Test("The presentation selector returns exactly what the specific placements return")
    func presentationSelectorAgrees() {
        let size = CGSize(width: 180, height: 26)
        for screen in validFixtures {
            #expect(NotchGeometry.hudFrame(for: screen, presentation: .compact, contentSize: size)
                    == NotchGeometry.compactHUDFrame(for: screen, contentSize: size))
            #expect(NotchGeometry.hudFrame(for: screen, presentation: .expanded, contentSize: size)
                    == NotchGeometry.expandedHUDFrame(for: screen, contentSize: size))
        }
        #expect(HUDPresentation(isExpanded: true) == .expanded)
        #expect(HUDPresentation(isExpanded: false) == .compact)
    }

    @Test("An external display attached to a notched laptop is placed on its own terms")
    func externalNextToNotchedLaptopIsIndependent() {
        let compact = NotchGeometry.compactHUDFrame(for: external, contentSize: CGSize(width: 160, height: 28))
        let expanded = NotchGeometry.expandedHUDFrame(for: external, contentSize: CGSize(width: 420, height: 360))
        #expect(external.frame.contains(compact))
        #expect(external.frame.contains(expanded))
        // The built-in display's notch must not leak into the external display's maths.
        #expect(compact.intersects(builtIn.frame) == false)
        #expect(expanded.intersects(builtIn.frame) == false)
    }
}
