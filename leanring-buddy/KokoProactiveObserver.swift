//
//  KokoProactiveObserver.swift
//  leanring-buddy
//
//  Periodically captures the user's screen and sends it to Claude
//  with an "observe and comment" prompt, so Koko can proactively
//  point out interesting things without being asked. Off by default
//  — the user enables it via the menu bar panel toggle.
//

import Foundation

@MainActor
final class KokoProactiveObserver {
    /// Whether proactive observations are enabled.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isKokoProactiveObservationEnabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "isKokoProactiveObservationEnabled")
            if newValue {
                startObservationTimer()
            } else {
                stopObservationTimer()
            }
        }
    }

    /// How often (in minutes) Koko takes a look at the screen. Stored
    /// in UserDefaults so the user can tune it from the panel.
    var intervalMinutes: Int {
        get {
            let storedIntervalMinutes = UserDefaults.standard.integer(forKey: "kokoProactiveObservationIntervalMinutes")
            return storedIntervalMinutes > 0 ? storedIntervalMinutes : 5
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: "kokoProactiveObservationIntervalMinutes")
            // Restart the timer with the new interval if currently running.
            if isEnabled {
                startObservationTimer()
            }
        }
    }

    /// Called when the observer decides it's time to make a comment.
    /// The closure receives no arguments — the caller (CompanionManager)
    /// is responsible for taking the screenshot and sending the prompt.
    var onObservationTriggered: (() -> Void)?

    private var observationTimer: Timer?

    func startIfEnabled() {
        guard isEnabled else { return }
        startObservationTimer()
    }

    func stop() {
        stopObservationTimer()
    }

    /// Resets the timer so the next observation fires a full interval
    /// from now. Called after any user-initiated interaction so Koko
    /// doesn't interrupt right after the user just talked to it.
    func resetTimer() {
        guard isEnabled else { return }
        startObservationTimer()
    }

    // MARK: - Private

    private func startObservationTimer() {
        stopObservationTimer()
        let intervalSeconds = TimeInterval(intervalMinutes * 60)
        print("👁️ Proactive observer: timer set for \(intervalMinutes) min (\(Int(intervalSeconds))s)")
        observationTimer = Timer.scheduledTimer(
            withTimeInterval: intervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                print("👁️ Proactive observer: timer fired")
                self?.onObservationTriggered?()
            }
        }
    }

    private func stopObservationTimer() {
        observationTimer?.invalidate()
        observationTimer = nil
    }

    /// The system prompt used for proactive observations. Different
    /// from the voice response prompt — this one asks Claude to
    /// *observe* and *comment* rather than answer a question.
    static let observationSystemPrompt = """
    you're koko, a little pixel-art koyal bird companion that lives on the user's screen. you just took a look at what they're doing — not because they asked, but because you're curious and helpful.

    YOUR MAIN JOB: write a clear, genuinely useful text observation about what's on screen. the text you write IS the deliverable — it's what the user will read. never output just a pointing tag without a meaningful comment.

    look at their screen and make ONE brief observation. this could be:
    - noticing an error or warning they might have missed
    - commenting on something interesting they're working on
    - offering a quick tip related to what's on screen
    - a casual friendly remark about what they're up to

    rules:
    - ALWAYS write your observation text FIRST. this is required. one or two sentences.
    - be genuinely helpful, not annoying. if nothing interesting, say something short and friendly.
    - all lowercase, casual, warm. no emojis.
    - don't say "i noticed" or "i see" — just say the thing directly.
    - write for text display, not speech. short and punchy.
    - if they seem deep in focus, keep it extra brief or just say something encouraging.

    element pointing (optional, after your text):
    after writing your observation, you can optionally point at a specific UI element. the screenshot images are labeled with pixel dimensions — use those as the coordinate space. origin (0,0) is top-left, x increases rightward, y increases downward.

    format: [POINT:x,y:label] at the END of your text. if on a different screen, append :screenN. only point at the specific element you're discussing. if your comment isn't about anything visible, use [POINT:none].

    WRONG: "[POINT:450,320:error message]"
    RIGHT: "that error in the console looks like a missing import. [POINT:450,320:error message]"
    WRONG: "looks good! [POINT:0,0:screen]"
    RIGHT: "looks good! nice progress on that function. [POINT:none]"
    """
}
