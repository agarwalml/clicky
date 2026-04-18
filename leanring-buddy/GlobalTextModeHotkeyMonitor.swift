//
//  GlobalTextModeHotkeyMonitor.swift
//  leanring-buddy
//
//  Watches for the app-wide Ctrl+Shift+T shortcut that toggles Koko's
//  text-only response mode. In text-only mode, Claude's responses are
//  streamed into a big text panel next to the bird instead of being
//  spoken aloud via ElevenLabs — handy when you're in a meeting,
//  wearing no headphones, or reviewing code that you want to *read*
//  rather than hear.
//
//  Same pattern as `GlobalPanelHotkeyMonitor`: a default-mode CGEvent
//  tap so the shortcut is *consumed* rather than passed through to
//  the foreground app. Without consumption Ctrl+Shift+T would also
//  fire in browsers (which use it for "reopen closed tab" in some
//  builds) and text editors.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalTextModeHotkeyMonitor: ObservableObject {
    /// Fires once each time the user presses Ctrl+Shift+T globally.
    let textModeHotkeyPressedPublisher = PassthroughSubject<Void, Never>()

    /// macOS virtual key code for the "T" key.
    private static let tKeyCode: UInt16 = 17

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

            let globalTextModeHotkeyMonitor = Unmanaged<GlobalTextModeHotkeyMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalTextModeHotkeyMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        // .defaultTap (not .listenOnly) lets us *consume* the Ctrl+Shift+T
        // event by returning nil from the callback. Without consumption
        // the foreground app would also receive the keystroke and
        // potentially run its own "reopen closed tab" / insert-T handler.
        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Text mode hotkey: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Text mode hotkey: couldn't create event tap run loop source")
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
        guard eventKeyCode == Self.tKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)

        // Require Ctrl+Shift+T exclusively — no Cmd, no Option. This
        // keeps us out of the way of Cmd+Shift+T (reopen closed tab
        // in browsers) and Option+Shift+T / Cmd+Option+T variants.
        let isPureControlShiftT =
            modifierFlags.contains(.control)
            && modifierFlags.contains(.shift)
            && !modifierFlags.contains(.command)
            && !modifierFlags.contains(.option)

        guard isPureControlShiftT else {
            return Unmanaged.passUnretained(event)
        }

        textModeHotkeyPressedPublisher.send(())

        // Returning nil consumes the event so the foreground app
        // doesn't also see the keystroke.
        return nil
    }
}
