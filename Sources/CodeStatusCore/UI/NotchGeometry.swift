import CoreGraphics

/// A display reduced to the handful of facts the HUD's placement depends on.
///
/// Deliberately not `NSScreen`: CodeStatusCore must build without AppKit so the
/// placement rules can be exercised in tests with no display attached, and so a
/// reported bad layout can be replayed as a fixture instead of reproduced on
/// hardware. The app target owns the one-line translation from `NSScreen`.
///
/// Every rectangle is in AppKit's global screen space — origin bottom-left, `y`
/// increasing upwards — so the menu bar and the notch live at ``frame``'s
/// `maxY`, and a display arranged to the left of the built-in one has a negative
/// `minX`. Nothing here assumes the main display sits at the origin.
public struct ScreenDescription: Sendable, Equatable {
    public var frame: CGRect

    /// `NSScreen.safeAreaInsets.top` (macOS 12+), which is greater than zero
    /// only on a display with a camera housing.
    public var safeAreaTopInset: CGFloat

    /// `NSScreen.auxiliaryTopLeftArea` (macOS 12+): the unobscured strip to the
    /// left of the camera housing, and one of the two places AppKit is willing
    /// to put menu bar items. The notch is the gap between the two areas.
    public var auxiliaryTopLeftArea: CGRect?

    /// `NSScreen.auxiliaryTopRightArea` — the strip menu bar extras occupy.
    public var auxiliaryTopRightArea: CGRect?

    /// Used only to snap frames to the display's physical pixel grid. Displays
    /// in one arrangement routinely differ here (2.0 built-in, 1.0 external),
    /// which is why it travels with the screen rather than being read globally.
    public var backingScaleFactor: CGFloat

    public init(
        frame: CGRect,
        safeAreaTopInset: CGFloat = 0,
        auxiliaryTopLeftArea: CGRect? = nil,
        auxiliaryTopRightArea: CGRect? = nil,
        backingScaleFactor: CGFloat = 2
    ) {
        self.frame = frame
        self.safeAreaTopInset = safeAreaTopInset
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
        self.backingScaleFactor = backingScaleFactor
    }
}

/// Which of the HUD's two shapes is on screen.
public enum HUDPresentation: String, Sendable, CaseIterable {
    /// The counter pill that lives in the notch.
    case compact
    /// The panel that hangs below the menu bar.
    case expanded

    public init(isExpanded: Bool) {
        self = isExpanded ? .expanded : .compact
    }
}

/// Where the HUD goes, as pure functions of a display's geometry.
///
/// Two hard rules drive every decision here, because both are user-visible
/// breakage rather than cosmetics:
///
/// 1. The compact pill is confined to the notch. The menu bar cannot place items
///    inside the camera housing's footprint, so a window that stays strictly
///    within it cannot cover — or swallow the clicks of — anybody's menu bar
///    item. The moment we spill into an auxiliary area that guarantee is gone.
/// 2. No frame is ever NaN, infinite, or negatively sized. AppKit will happily
///    accept such a frame and then place the window somewhere unrecoverable,
///    off every display, with no way for the user to get it back.
public enum NotchGeometry {
    /// Fallback menu bar height for displays with no safe-area inset. The real
    /// value is only reachable through AppKit (`NSMenu.menuBarHeight`), which
    /// this module cannot import; 24pt is the standard-density menu bar and any
    /// small error only shifts a floating pill, it never breaks a guarantee.
    public static let standardMenuBarHeight: CGFloat = 24

    /// Keeps a floating HUD off the screen's edges, where the Dock, rounded
    /// display corners, and other displays' seams live.
    public static let screenEdgeMargin: CGFloat = 8

    /// Separation between the menu bar's lower edge and a floating pill, so the
    /// pill reads as a distinct object rather than a menu bar extra.
    public static let menuBarGap: CGFloat = 6

    /// The camera housing's corners are rounded, so content flush against the
    /// notch's left or right edge gets visibly nicked.
    public static let notchHorizontalInset: CGFloat = 4

    /// Keeps the pill off the top bezel and off the notch's lower lip.
    public static let notchVerticalInset: CGFloat = 2

    /// The floor applied to requested content. A zero-sized window cannot be
    /// ordered on screen, so a caller that has not measured its content yet gets
    /// the smallest visible pill instead of an invisible window that reads as a
    /// crash.
    public static let minimumContentSize = CGSize(width: 16, height: 8)
}

public extension NotchGeometry {
    /// Whether this display can host the pill inside a camera housing.
    ///
    /// True only when a notch rect is actually derivable: a display that reports
    /// a safe-area inset but no auxiliary areas is treated as un-notched,
    /// because without the gap's horizontal extent we cannot promise a pill
    /// clear of the menu bar — see ``notchRect(for:)``.
    static func isNotched(_ screen: ScreenDescription) -> Bool {
        notchRect(for: screen) != nil
    }

    /// The camera housing's footprint, in the screen's own coordinate space.
    ///
    /// Derived from the auxiliary areas rather than from any hardware table:
    /// the gap between them *is* the region AppKit refuses to lay menu bar items
    /// into, which is the property the HUD depends on. Returns nil unless the
    /// display reports a safe-area inset *and* both auxiliary areas *and* a
    /// positive gap between them — anything less is not enough evidence to place
    /// a window over the menu bar.
    static func notchRect(for screen: ScreenDescription) -> CGRect? {
        guard screen.safeAreaTopInset.isFinite, screen.safeAreaTopInset > 0 else { return nil }
        guard let frame = usableRect(screen.frame),
              let left = usableRect(screen.auxiliaryTopLeftArea),
              let right = usableRect(screen.auxiliaryTopRightArea)
        else { return nil }

        let width = right.minX - left.maxX
        guard width > 0 else { return nil }

        // The auxiliary areas are as tall as the housing; trust whichever
        // measurement is largest so the pill is never clipped by a rect we
        // under-measured.
        let height = max(screen.safeAreaTopInset, max(left.height, right.height))
        let candidate = CGRect(x: left.maxX, y: frame.maxY - height, width: width, height: height)
        // Intersecting also rejects auxiliary areas that belong to a different
        // display than the frame, which is a real possibility when the caller
        // assembles a description from mismatched sources.
        return usableRect(candidate.intersection(frame))
    }

    /// The height of the menu bar strip at the top of this display.
    static func menuBarHeight(for screen: ScreenDescription) -> CGFloat {
        guard screen.safeAreaTopInset.isFinite, screen.safeAreaTopInset > 0 else {
            return standardMenuBarHeight
        }
        return screen.safeAreaTopInset
    }

    /// The largest content a caller can lay out and still be placed in the
    /// notch, or nil on a display without one. Callers that would rather shrink
    /// their content than be relocated below the menu bar size against this.
    static func maximumCompactContentSize(for screen: ScreenDescription) -> CGSize? {
        guard let notch = notchRect(for: screen),
              let available = usableRect(notch.insetBy(dx: notchHorizontalInset, dy: notchVerticalInset))
        else { return nil }
        return available.size
    }

    /// Where the compact counter pill sits.
    ///
    /// On a notched display the result is strictly inside ``notchRect(for:)``
    /// and therefore cannot intersect either auxiliary area.
    ///
    /// Policy for content that does not fit the notch: the pill is *relocated*
    /// below the menu bar (``nonNotchedHUDFrame(for:contentSize:)``), not
    /// clamped to the notch's width. Clamping would silently clip the counters,
    /// and a HUD that reports "3 agents" when four need you is worse than a HUD
    /// that moved. Callers that prefer to shrink can consult
    /// ``maximumCompactContentSize(for:)`` before asking.
    static func compactHUDFrame(for screen: ScreenDescription, contentSize: CGSize) -> CGRect {
        guard let notch = notchRect(for: screen),
              let available = usableRect(notch.insetBy(dx: notchHorizontalInset, dy: notchVerticalInset))
        else {
            return nonNotchedHUDFrame(for: screen, contentSize: contentSize)
        }

        let content = sanitized(contentSize)
        guard content.width <= available.width, content.height <= available.height else {
            return nonNotchedHUDFrame(for: screen, contentSize: contentSize)
        }

        let centred = CGRect(
            x: available.midX - content.width / 2,
            y: available.midY - content.height / 2,
            width: content.width,
            height: content.height
        )
        return pixelAligned(centred, within: notch, scale: screen.backingScaleFactor)
    }

    /// Where the expanded panel sits: hanging from the menu bar's lower edge,
    /// centred under the notch so it reads as dropping out of it, and clamped
    /// so it never leaves the display it belongs to.
    ///
    /// Content taller or wider than the display is shrunk to fit rather than
    /// overflowing, because a panel whose action buttons are off-screen cannot
    /// be used at all.
    static func expandedHUDFrame(for screen: ScreenDescription, contentSize: CGSize) -> CGRect {
        guard let area = layoutArea(for: screen) else { return .zero }
        let content = fit(sanitized(contentSize), in: area.size)
        let candidate = CGRect(
            x: anchorX(for: screen) - content.width / 2,
            y: area.maxY - content.height,
            width: content.width,
            height: content.height
        )
        return pixelAligned(candidate, within: area, scale: screen.backingScaleFactor)
    }

    /// The compact pill for a display with no notch: a floating pill just below
    /// the menu bar. Macs without a camera housing are not second-class here —
    /// they get the same HUD, just parked in ordinary screen space.
    ///
    /// Centred on the notch when there is one (this is also the relocation
    /// target for over-wide notch content), otherwise on the display.
    static func nonNotchedHUDFrame(for screen: ScreenDescription, contentSize: CGSize) -> CGRect {
        guard let area = layoutArea(for: screen) else { return .zero }
        let content = fit(sanitized(contentSize), in: area.size)
        let candidate = CGRect(
            x: anchorX(for: screen) - content.width / 2,
            y: area.maxY - menuBarGap - content.height,
            width: content.width,
            height: content.height
        )
        return pixelAligned(candidate, within: area, scale: screen.backingScaleFactor)
    }

    /// The frame for the HUD in its current shape — the entry point the window
    /// controller calls, so expansion state is the only thing it has to track.
    static func hudFrame(
        for screen: ScreenDescription,
        presentation: HUDPresentation,
        contentSize: CGSize
    ) -> CGRect {
        switch presentation {
        case .compact: return compactHUDFrame(for: screen, contentSize: contentSize)
        case .expanded: return expandedHUDFrame(for: screen, contentSize: contentSize)
        }
    }
}

private extension NotchGeometry {
    /// The region a floating HUD may occupy: below the menu bar, inside a margin
    /// on the other three edges.
    ///
    /// The margins are dropped, then the menu bar reservation is dropped, on
    /// displays too small to afford them. A display that small is pathological
    /// (a mirrored projector mode, a synthesized fixture), but returning an
    /// empty region there would hand AppKit a zero-sized window.
    static func layoutArea(for screen: ScreenDescription) -> CGRect? {
        guard let frame = usableRect(screen.frame) else { return nil }
        let belowMenuBar = frame.height - menuBarHeight(for: screen)

        let inset = CGRect(
            x: frame.minX + screenEdgeMargin,
            y: frame.minY + screenEdgeMargin,
            width: frame.width - 2 * screenEdgeMargin,
            height: belowMenuBar - screenEdgeMargin
        )
        if let usable = usableRect(inset) { return usable }

        let bare = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: belowMenuBar)
        if let usable = usableRect(bare) { return usable }

        return frame
    }

    /// The x the HUD centres on: the notch when there is one, so the compact and
    /// expanded shapes share an axis and the expansion animation is a straight
    /// vertical growth rather than a slide.
    static func anchorX(for screen: ScreenDescription) -> CGFloat {
        if let notch = notchRect(for: screen) { return notch.midX }
        return usableRect(screen.frame)?.midX ?? 0
    }

    /// Rejects the rects AppKit would accept and then misplace: NaN or infinite
    /// components, and empty or inverted ones.
    ///
    /// An inverted rect is rejected rather than standardized on purpose. A
    /// display whose reported frame has a negative width is corrupt input, and
    /// standardizing it would invent a plausible-looking location out of
    /// nothing — exactly the kind of guess this product does not make.
    static func usableRect(_ rect: CGRect?) -> CGRect? {
        guard let rect,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0
        else { return nil }
        return rect
    }

    static func sanitized(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite ? max(size.width, minimumContentSize.width) : minimumContentSize.width,
            height: size.height.isFinite ? max(size.height, minimumContentSize.height) : minimumContentSize.height
        )
    }

    static func fit(_ size: CGSize, in available: CGSize) -> CGSize {
        CGSize(
            width: min(size.width, max(available.width, 0)),
            height: min(size.height, max(available.height, 0))
        )
    }

    /// Moves and, if necessary, shrinks `rect` until it is inside `container`.
    /// Shrinking comes first so the clamp is well defined even when the caller
    /// asked for something larger than the display.
    static func clamped(_ rect: CGRect, into container: CGRect) -> CGRect {
        let width = min(max(rect.width, 0), max(container.width, 0))
        let height = min(max(rect.height, 0), max(container.height, 0))
        let x = min(max(rect.minX, container.minX), container.maxX - width)
        let y = min(max(rect.minY, container.minY), container.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Snaps a clamped frame to the display's pixel grid.
    ///
    /// A half-pixel origin makes the pill's 1pt border and its text render
    /// blurry, and the notch's edges are the one place on screen where that is
    /// unmissable. The size is rounded *down* so alignment can never push a
    /// frame back over the edge it was just clamped to; the final clamp catches
    /// the origin rounding for containers that are not themselves aligned.
    static func pixelAligned(_ rect: CGRect, within container: CGRect, scale: CGFloat) -> CGRect {
        let base = clamped(rect, into: container)
        guard scale.isFinite, scale >= 1 else { return base }
        let aligned = CGRect(
            x: (base.minX * scale).rounded() / scale,
            y: (base.minY * scale).rounded() / scale,
            width: (base.width * scale).rounded(.down) / scale,
            height: (base.height * scale).rounded(.down) / scale
        )
        return clamped(aligned, into: container)
    }
}
