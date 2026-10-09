import AppKit
import CoreGraphics

/// A modifier key that can start a dictation on its own.
enum HotkeyKey: String, CaseIterable, Identifiable {
    case rightCommand, rightOption, rightControl, fn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightCommand: "Right ⌘ Command"
        case .rightOption: "Right ⌥ Option"
        case .rightControl: "Right ⌃ Control"
        case .fn: "fn"
        }
    }

    var symbol: String {
        switch self {
        case .rightCommand: "right ⌘"
        case .rightOption: "right ⌥"
        case .rightControl: "right ⌃"
        case .fn: "fn"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .rightControl: 62
        case .fn: 63
        }
    }

    /// Flag bit that is set while this exact key is down. Right-side keys
    /// use the device-dependent masks (NX_DEVICER*KEYMASK) so the left-hand
    /// key never triggers.
    var downMask: UInt64 {
        switch self {
        case .rightCommand: 0x10
        case .rightOption: 0x40
        case .rightControl: 0x2000
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }
}

/// The gesture logic, free of event taps so it can be unit tested.
///
/// - hold the key, talk, release: push-to-talk
/// - tap it (shorter than `tapThreshold`): hands-free; tap again to stop
/// - another key while the hotkey is held: it was a shortcut, cancel
/// - Escape while recording: cancel
struct HotkeyStateMachine {
    enum Event: Equatable { case start, stop, cancel }

    /// Generous: a relaxed tap often lasts 300+ ms, and reading it as a hold
    /// stops the recording the moment it starts.
    var tapThreshold: TimeInterval = 0.6

    private(set) var pressedAt: Date?
    private(set) var handsFree = false
    private(set) var recording = false

    mutating func hotkeyDown(at now: Date) -> Event? {
        if handsFree {
            reset()
            return .stop
        }
        pressedAt = now
        recording = true
        // Start on press, not release, so the first word is not clipped.
        return .start
    }

    mutating func hotkeyUp(at now: Date) -> Event? {
        guard let pressedAt, recording else { return nil }
        self.pressedAt = nil
        if now.timeIntervalSince(pressedAt) < tapThreshold {
            handsFree = true
            return nil
        }
        reset()
        return .stop
    }

    mutating func otherKeyDown(isEscape: Bool) -> Event? {
        guard recording, isEscape || pressedAt != nil else { return nil }
        reset()
        return .cancel
    }

    private mutating func reset() {
        pressedAt = nil
        handsFree = false
        recording = false
    }
}

/// Watches the chosen hotkey system-wide with a listen-only event tap. It can
/// see keys, never change them. That needs Input Monitoring; macOS 27 shows
/// it as Device Control and Data Access and decides it through Accessibility.
final class HotkeyMonitor {
    var onEvent: ((HotkeyStateMachine.Event) -> Void)?
    /// Read on every event, so a change in Settings applies immediately.
    var key: () -> HotkeyKey = { .rightCommand }

    private static let escapeKeyCode: Int64 = 53
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Whether Input Monitoring was granted when the tap was made.
    private var tapPermitted = false
    private var machine = HotkeyStateMachine()

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// What System Settings calls the permission: macOS 27 folds Input
    /// Monitoring into Device Control and Data Access.
    static var permissionName: String {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            ? "Device Control and Data Access" : "Input Monitoring"
    }
    static func requestPermission() { CGRequestListenEventAccess() }

    /// Opens the pane where TalkToMe is switched on, or Privacy & Security
    /// if this macOS does not know the pane's link.
    static func openSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security"
        if !NSWorkspace.shared.open(URL(string: pane + "?Privacy_ListenEvent")!) {
            NSWorkspace.shared.open(URL(string: pane)!)
        }
    }

    /// The permissions an ad-hoc signed build gets tied to: the hotkey's and
    /// the paste's. macOS 27 decides the hotkey through Accessibility too, so
    /// resetting Input Monitoring alone leaves a stale Accessibility answer
    /// that still denies it.
    private static let services = ["ListenEvent", "PostEvent", "Accessibility"]

    /// Forgets this app's answers for `services`. After an update macOS denies
    /// the new build in silence and `CGRequestListenEventAccess` asks nothing
    /// while the answer is "denied"; after a reset it asks again.
    static func resetPermissions() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return services.map { service in
            let reset = Process()
            reset.executableURL = URL(filePath: "/usr/bin/tccutil")
            reset.arguments = ["reset", service, id]
            do {
                try reset.run()
                reset.waitUntilExit()
            } catch {
                return false
            }
            return reset.terminationStatus == 0
        }.allSatisfy { $0 }
    }

    /// Starts listening; true only if the hotkey will work in every app.
    /// Without Input Monitoring macOS still creates the tap, but only passes
    /// it keys typed into TalkToMe itself, so the tap alone proves nothing.
    @discardableResult
    func start() -> Bool {
        let permitted = Self.hasPermission
        if tap != nil, permitted == tapPermitted { return permitted }
        stop()
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return false }
        self.tap = tap
        tapPermitted = permitted
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        EventLog.write("hotkey tap started, permitted=\(permitted)")
        return permitted
    }

    private func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = Date()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches slow taps off; switch it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            emit(machine.otherKeyDown(isEscape: keyCode == Self.escapeKeyCode))
        case .flagsChanged:
            let key = key()
            guard event.getIntegerValueField(.keyboardEventKeycode) == key.keyCode else { return }
            let isDown = event.flags.rawValue & key.downMask != 0
            EventLog.write("\(key.rawValue) \(isDown ? "down" : "up")")
            emit(isDown ? machine.hotkeyDown(at: now) : machine.hotkeyUp(at: now))
        default:
            break
        }
    }

    private func emit(_ event: HotkeyStateMachine.Event?) {
        guard let event else { return }
        EventLog.write("hotkey \(event) handsFree=\(machine.handsFree)")
        DispatchQueue.main.async { self.onEvent?(event) }
    }
}
