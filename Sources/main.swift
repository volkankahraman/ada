import AppKit
import SwiftUI

/// Clicks land on the island even though the app never becomes active.
final class HostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Takes the keyboard only while you type in a text field (the plan notes), so it never steals focus otherwise.
/// Non-activating: the app you were in stays frontmost the whole time.
final class KeyPanel: NSPanel {
    private var typing = false
    override var canBecomeKey: Bool { typing }

    override func sendEvent(_ event: NSEvent) {
        // hitTest takes superview coordinates, which are window coordinates for the content view.
        if event.type == .leftMouseDown, !isKeyWindow, contentView?.hitTest(event.locationInWindow) is NSText {
            typing = true
            makeKey()
        }
        super.sendEvent(event)
    }

    /// Hand the keyboard back once the field is gone (decided, closed). Clicking another window does that on its own.
    func releaseKey() {
        guard isKeyWindow, !(firstResponder is NSText) else { return }
        typing = false
        // ponytail: ordering out a key non-activating panel returns focus to the frontmost app; resignKey() alone does not.
        orderOut(nil)
        orderFrontRegardless()
    }

    override func resignKey() {
        super.resignKey()
        typing = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var server: HookServer!
    var panel: KeyPanel!
    let panelSize = CGSize(width: 720, height: 900) // tall enough for a multi-question card
    var lastPending = 0
    var autoOpened = false

    var screen: NSScreen { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0] }

    func applicationDidFinishLaunching(_ note: Notification) {
        let setupNote = Setup.onLaunch()
        let dir = NSHomeDirectory() + "/.ada"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            server = try HookServer(path: dir + "/ada.sock")
        } catch {
            NSLog("ada: cannot open socket: \(error)")
            exit(1)
        }
        server.onRequest = { [store] h, b, c in store.handle(h, b, c) }

        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = HostingView(rootView: IslandView(store: store))
        layout()
        panel.orderFrontRegardless()
        if !UserDefaults.standard.bool(forKey: "welcomed") { // first launch: say hello instead of sitting there invisible
            store.welcome = setupNote
            store.setExpanded(true)
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.layout()
        }
        // ponytail: polling the cursor is simpler and more reliable than tracking areas on a non-key panel.
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackMouse() }
        refreshUsage()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refreshUsage() }
        // Sessions fall asleep by the clock, not by an event, so redraw once a minute.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [store] _ in store.objectWillChange.send() }
    }

    func refreshUsage() {
        Task { @MainActor [store] in
            do {
                store.usage = try await ClaudeAuth.usage()
                store.usageError = nil
            } catch {
                store.usageError = error.localizedDescription
                NSLog("ada: usage: \(error.localizedDescription)")
            }
        }
    }

    func layout() {
        let f = screen.frame
        let left = screen.auxiliaryTopLeftArea?.width ?? f.width / 2
        let right = screen.auxiliaryTopRightArea?.width ?? f.width / 2
        store.notchWidth = max(0, f.width - left - right)
        store.notchHeight = max(screen.safeAreaInsets.top, f.maxY - screen.visibleFrame.maxY, 24)
        panel.setFrame(NSRect(x: f.midX - panelSize.width / 2, y: f.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    func trackMouse() {
        let f = screen.frame, size = store.islandSize
        let island = NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height, width: size.width, height: size.height)
        let inside = island.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        // The panel is much bigger than the island; let clicks fall through everywhere else.
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside } // setting it even unchanged costs a window-server round trip

        // Opens on click (see IslandView). A new approval request pops it open on its own,
        // and it folds back once that request is answered.
        let pending = store.pendingCount
        if pending > lastPending && !store.expanded {
            autoOpened = true
            store.setExpanded(true)
        } else if pending == 0 && lastPending > 0 && autoOpened {
            autoOpened = false
            store.setExpanded(false)
        }
        lastPending = pending
        panel.releaseKey()

        // A click anywhere outside closes it.
        if store.expanded && !inside && NSEvent.pressedMouseButtons & 1 != 0 {
            autoOpened = false
            store.setExpanded(false)
        }
    }
}

Setup.cli(CommandLine.arguments) // exits when given --install-hooks/--uninstall-hooks
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
