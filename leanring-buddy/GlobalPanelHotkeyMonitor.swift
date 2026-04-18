//
//  GlobalPanelHotkeyMonitor.swift
//  leanring-buddy
//
//  Watches for the app-wide Option+Space shortcut that toggles the menu bar
//  companion panel. Uses a default-mode (not listen-only) CGEvent tap so the
//  shortcut is *consumed* rather than passed through to the foreground app —
//  otherwise Option+Space would also insert a non-breaking space into any
//  text field that happens to be focused when the user hits the shortcut.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPanelHotkeyMonitor: ObservableObject {
    /// Fires once every time the user presses Option+Space globally.
    let panelHotkeyPressedPublisher = PassthroughSubject<Void, Never>()

    /// Spacebar key code. Matches the constant used by the push-to-talk
    /// monitor so both shortcut surfaces agree on what "space" means.
    private static let spaceKeyCode: UInt16 = 49

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it. The
        // permission poller calls refreshAllPermissions → start() every
        // 1.5 seconds, and recreating the tap on every tick would waste
        // cycles and potentially drop the very next keystroke.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.keyDown]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPanelHotkeyMonitor = Unmanaged<GlobalPanelHotkeyMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPanelHotkeyMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        // .defaultTap (not .listenOnly) lets us *consume* the Option+Space
        // event by returning nil from the callback. Without consumption the
        // foreground app would also receive the keystroke and insert a
        // non-breaking space into whatever text field was focused.
        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global panel hotkey: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global panel hotkey: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // macOS occasionally disables the tap (timeout or user input burst).
        // Re-enable it immediately so the hotkey keeps working.
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard eventType == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == Self.spaceKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)

        // Require *only* Option (no Command, Control, Shift). This keeps us
        // from colliding with existing system or app shortcuts like
        // Cmd+Option+Space, Shift+Option+Space, or Control+Option+Space.
        let isPureOptionSpace =
            modifierFlags.contains(.option)
            && !modifierFlags.contains(.command)
            && !modifierFlags.contains(.control)
            && !modifierFlags.contains(.shift)

        guard isPureOptionSpace else {
            return Unmanaged.passUnretained(event)
        }

        panelHotkeyPressedPublisher.send(())

        // Returning nil consumes the event so the foreground app never sees
        // it — no rogue non-breaking space gets inserted into the user's
        // current document or text field.
        return nil
    }
}
