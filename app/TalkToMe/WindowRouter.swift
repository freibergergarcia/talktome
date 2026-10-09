import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item, its drop-down panel and the Settings window.
///
/// Built on AppKit rather than SwiftUI's MenuBarExtra because the panel must
/// open on demand: launching TalkToMe from Finder, Spotlight or the Dock drops
/// it down, and MenuBarExtra has no API for that. The Dock icon follows the
/// "Show in Dock" setting, and always appears while Settings is open.
@MainActor
final class WindowRouter: NSObject, NSWindowDelegate {
    static private(set) var shared: WindowRouter?

    private let dictation: Dictation
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: DropDownPanel
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?

    init(dictation: Dictation) {
        self.dictation = dictation
        panel = DropDownPanel(content: HomePanel(dictation: dictation))
        super.init()
        Self.shared = self

        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        updateIcon()
        applyDockPolicy()
        dictation.settings.onShowInDockChange = { [weak self] in self?.applyDockPolicy() }
        panel.onClose = { [weak self] in self?.stopWatchingOutsideClicks() }
    }

    // MARK: - Panel

    @objc private func toggle() {
        panel.isVisible ? closePanel() : showPanel()
    }

    func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // Take focus first; otherwise the panel loses key status the moment
        // macOS finishes activating whatever was in front, and closes.
        NSApp.activate()
        dictation.refreshHotkeyPermission()
        panel.show(below: anchor)
        button.highlight(true)
        // Clicking anywhere else closes it, like a menu.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    func closePanel() {
        panel.orderOut(nil)
        stopWatchingOutsideClicks()
    }

    private func stopWatchingOutsideClicks() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        statusItem.button?.highlight(false)
    }

    // MARK: - Settings

    func showSettings() {
        closePanel()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(settings: dictation.settings, dictation: dictation)
            ))
            window.title = "TalkToMe Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Settings is closing, so only the setting decides now.
        DispatchQueue.main.async { self.applyDockPolicy() }
    }

    private func applyDockPolicy() {
        let settingsOpen = settingsWindow?.isVisible ?? false
        NSApp.setActivationPolicy(dictation.settings.showInDock || settingsOpen ? .regular : .accessory)
    }

    // MARK: - Icon

    /// Follows the dictation phase: waveform at rest, mic while recording.
    private func updateIcon() {
        let symbol = withObservationTracking {
            switch dictation.phase {
            case .idle, .done: "waveform"
            case .recording: "mic.fill"
            case .transcribing: "ellipsis"
            case .failed: "exclamationmark.triangle"
            }
        } onChange: {
            Task { @MainActor [weak self] in self?.updateIcon() }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TalkToMe")
        image?.isTemplate = true
        statusItem.button?.image = image
    }
}

/// A borderless panel that hangs below the menu bar item, like a menu.
final class DropDownPanel: NSPanel {
    var onClose: (() -> Void)?

    init(content: some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        contentView = NSHostingView(rootView: content
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 0.5)))
    }

    // Borderless windows refuse key status by default; buttons and hover
    // need it.
    override var canBecomeKey: Bool { true }

    func show(below anchor: NSRect) {
        guard let content = contentView else { return }
        let size = content.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        orderOut(nil)
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onClose?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Opened by hand (Finder, Spotlight, Dock): drop the panel down.
    /// Started at login: stay quietly in the menu bar.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }), !Self.launchedAtLogin else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { WindowRouter.shared?.showPanel() }
        }
    }

    private static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        // Login items are not always flagged; right after boot, assume login.
        return ProcessInfo.processInfo.systemUptime < 180
    }

    /// Opening the app again while it runs (double-click in Finder, Spotlight,
    /// Dock) shows the panel instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { WindowRouter.shared?.showPanel() }
        return true
    }
}
