import AppKit

// Built as an executable rather than a SwiftUI `App`, because CodeStatus owns
// no window: the HUD is an NSPanel and the menu bar item is an NSStatusItem,
// both of which want an AppKit lifecycle rather than a scene.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
