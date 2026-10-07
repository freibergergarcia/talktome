import Foundation
import Testing

@Suite struct HotkeyStateMachineTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func holdIsPushToTalk() {
        var machine = HotkeyStateMachine()
        #expect(machine.hotkeyDown(at: t0) == .start)
        #expect(machine.hotkeyUp(at: t0 + 1.5) == .stop)
        #expect(!machine.recording)
    }

    @Test func tapStartsHandsFreeAndSecondTapStops() {
        var machine = HotkeyStateMachine()
        #expect(machine.hotkeyDown(at: t0) == .start)
        #expect(machine.hotkeyUp(at: t0 + 0.15) == nil)
        #expect(machine.handsFree)
        #expect(machine.hotkeyDown(at: t0 + 4) == .stop)
        #expect(machine.hotkeyUp(at: t0 + 4.1) == nil)
        #expect(!machine.recording)
    }

    /// The bug from the field: relaxed taps of ~320 ms were read as holds and
    /// stopped the recording instantly.
    @Test func relaxedTapStillCountsAsTap() {
        var machine = HotkeyStateMachine()
        _ = machine.hotkeyDown(at: t0)
        #expect(machine.hotkeyUp(at: t0 + 0.321) == nil)
        #expect(machine.handsFree)
    }

    @Test func otherKeyWhileHeldIsAShortcut() {
        var machine = HotkeyStateMachine()
        _ = machine.hotkeyDown(at: t0)
        #expect(machine.otherKeyDown(isEscape: false) == .cancel)
        #expect(machine.hotkeyUp(at: t0 + 0.1) == nil)
        #expect(!machine.recording)
    }

    @Test func typingDuringHandsFreeDoesNotCancel() {
        var machine = HotkeyStateMachine()
        _ = machine.hotkeyDown(at: t0)
        _ = machine.hotkeyUp(at: t0 + 0.1)
        #expect(machine.otherKeyDown(isEscape: false) == nil)
        #expect(machine.recording)
    }

    @Test func escapeCancelsHandsFree() {
        var machine = HotkeyStateMachine()
        _ = machine.hotkeyDown(at: t0)
        _ = machine.hotkeyUp(at: t0 + 0.1)
        #expect(machine.otherKeyDown(isEscape: true) == .cancel)
        #expect(!machine.handsFree)
    }

    @Test func keysWhileIdleAreIgnored() {
        var machine = HotkeyStateMachine()
        #expect(machine.otherKeyDown(isEscape: true) == nil)
        #expect(machine.hotkeyUp(at: t0) == nil)
    }
}

@Suite struct HotkeyKeyTests {
    @Test func rightSideMasksAreDistinct() {
        let masks = HotkeyKey.allCases.map(\.downMask)
        #expect(Set(masks).count == masks.count)
        #expect(HotkeyKey.rightCommand.keyCode == 54)
    }
}
