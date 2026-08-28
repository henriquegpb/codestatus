import AppKit

// Built as an executable rather than a SwiftUI `App`, because CodeStatus owns
// no window: the HUD is an NSPanel and the menu bar item is an NSStatusItem,
// both of which want an AppKit lifecycle rather than a scene.
// Before the delegate exists, so a second copy never stages a hook binary,
// never binds the socket, and above all never unlinks the socket the running
// copy is listening on. Every one of those is a side effect that outlives the
// process that caused it.
if let existing = SingleInstance.otherInstance() {
    SingleInstance.handOff(to: existing)
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
