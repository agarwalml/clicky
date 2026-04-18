//
//  KokoNest.swift
//  leanring-buddy
//
//  After a configurable idle period (no user commands), Koko flies to
//  a random corner of the screen and nests there until the next
//  interaction. Gives the bird a sense of autonomy — it goes and
//  "sits somewhere" when you're not talking to it, rather than
//  mechanically tracking the cursor forever.
//
//  Independent from proactive screen observations — nesting is
//  purely visual/behavioral, not an AI interaction.
//

import AppKit
import Foundation

@MainActor
final class KokoNest {
    /// Whether nesting is enabled.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isKokoNestEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "isKokoNestEnabled")
            if newValue {
                resetIdleTimer()
            } else {
                stopIdleTimer()
                if isNesting {
                    isNesting = false
                    onShouldReturnFromNest?()
                }
            }
        }
    }

    /// How many minutes of no user commands before Koko flies to a
    /// corner. Stored in UserDefaults so the user can configure it.
    var idleMinutes: Int {
        get {
            let storedIdleMinutes = UserDefaults.standard.integer(forKey: "kokoNestIdleMinutes")
            return storedIdleMinutes > 0 ? storedIdleMinutes : 3
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: "kokoNestIdleMinutes")
            if isEnabled && !isNesting {
                resetIdleTimer()
            }
        }
    }

    /// Whether Koko is currently nesting in a corner (not following
    /// the cursor).
    private(set) var isNesting: Bool = false

    /// Called when the idle timer fires and Koko should fly to a
    /// corner. Receives the target screen position.
    var onShouldNest: ((CGPoint) -> Void)?

    /// Called when a user interaction happens while nesting and Koko
    /// should fly back to the cursor.
    var onShouldReturnFromNest: (() -> Void)?

    private var idleTimer: Timer?

    /// Resets the idle timer. Call this after every user interaction
    /// (PTT, typed command, wake word) so the countdown restarts.
    /// If currently nesting, signals return to cursor first.
    func resetIdleTimer() {
        if isNesting {
            isNesting = false
            onShouldReturnFromNest?()
        }

        guard isEnabled else { return }
        stopIdleTimer()

        let intervalSeconds = TimeInterval(idleMinutes * 60)
        idleTimer = Timer.scheduledTimer(
            withTimeInterval: intervalSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerNest()
            }
        }
    }

    /// Pauses the idle timer without triggering a return to cursor.
    /// Used when a proactive observation fires while nesting — the
    /// bird should stay at its nest position and show the observation
    /// text there, not fly back to the cursor.
    func pauseIdleTimerForObservation() {
        stopIdleTimer()
        // Do NOT set isNesting = false or call onShouldReturnFromNest.
        // The bird stays nested at its current position.
    }

    /// Restarts the idle timer after a proactive observation completes
    /// while nested. The bird stays at the nest — this just resets
    /// the countdown for the NEXT nest trigger (which is a no-op
    /// since it's already nesting).
    func resumeIdleTimerAfterObservation() {
        guard isEnabled, isNesting else { return }
        // No timer needed — bird is already nesting. The next user
        // interaction will call resetIdleTimer() and return from nest.
    }

    func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        resetIdleTimer()
    }

    /// Public entry point so CompanionManager can trigger nesting
    /// immediately (e.g. after a proactive observation finishes).
    func triggerNestNow() {
        triggerNest()
    }

    // MARK: - Private

    private func triggerNest() {
        guard isEnabled, !isNesting else { return }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let inset: CGFloat = 60

        let corners: [CGPoint] = [
            CGPoint(x: visibleFrame.minX + inset, y: visibleFrame.minY + inset),
            CGPoint(x: visibleFrame.maxX - inset, y: visibleFrame.minY + inset),
            CGPoint(x: visibleFrame.minX + inset, y: visibleFrame.maxY - inset),
            CGPoint(x: visibleFrame.maxX - inset, y: visibleFrame.maxY - inset)
        ]

        let mouseLocation = NSEvent.mouseLocation
        let chosenCorner = corners.max(by: { cornerA, cornerB in
            let distanceToA = hypot(cornerA.x - mouseLocation.x, cornerA.y - mouseLocation.y)
            let distanceToB = hypot(cornerB.x - mouseLocation.x, cornerB.y - mouseLocation.y)
            return distanceToA < distanceToB
        }) ?? corners[0]

        isNesting = true
        onShouldNest?(chosenCorner)
    }
}
