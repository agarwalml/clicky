//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    // MARK: - Startup Audio

    /// Quiet background music that plays once when the cursor overlay
    /// first appears on a regular (post-onboarding) launch.
    private var startupBackgroundMusicPlayer: AVAudioPlayer?

    /// Timer that fades out the startup BGM shortly after it begins so
    /// the bed doesn't overstay its welcome.
    private var startupBackgroundMusicFadeTimer: Timer?

    /// Short Koko "kookoo" voice jingle that plays on top of the startup
    /// BGM so the bird has an audible arrival alongside its intro flight.
    private var startupKookooIntroPlayer: AVAudioPlayer?

    let kokoSoundEffects = KokoSoundEffects()
    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    /// System-wide Option+Space hotkey that toggles the inline typed input
    /// overlay next to the bird. Gated behind accessibility permission,
    /// same as push-to-talk.
    let globalPanelHotkeyMonitor = GlobalPanelHotkeyMonitor()
    /// System-wide Ctrl+Shift+T hotkey that toggles text-only mode —
    /// responses stream into a big scrollable panel next to the bird
    /// instead of being spoken via ElevenLabs TTS.
    let globalTextModeHotkeyMonitor = GlobalTextModeHotkeyMonitor()
    let overlayWindowManager = OverlayWindowManager()
    /// Spotlight-style typed input that appears next to the koyal sprite
    /// when the user hits Option+Space. Shares its submission pipeline
    /// with push-to-talk via `submitTypedCommand(_:)`.
    let typedInputOverlayManager = CompanionTypedInputOverlayManager()

    /// Scrollable streaming text-response panel used when Koko is in
    /// text-only mode. Sits in the same slot next to the bird as the
    /// typed input overlay, but is bigger and persists until the user
    /// clicks away or hits Escape.
    let textResponseOverlayManager = CompanionTextResponseOverlayManager()

    /// On-device "Hey Koko" wake-word listener. Apple Speech backend
    /// for now; will be swapped for Porcupine once the license is
    /// active without any changes to the rest of the manager.
    let kokoWakeWordListener: any KokoWakeWordListener = AppleSpeechKokoWakeWordListener()

    /// Persistent session memory — stores conversation summaries in
    /// a human-readable `memory.md` that gets injected into Claude's
    /// system prompt so Koko remembers things across app launches.
    let kokoMemoryManager = KokoMemoryManager()

    /// Periodic unprompted screen observations — Koko takes a look
    /// at the screen every N minutes and comments on something.
    let kokoProactiveObserver = KokoProactiveObserver()

    /// Nest — after N minutes idle, Koko flies to a corner
    /// and perches until the user talks to it again.
    let kokoNest = KokoNest()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "https://clicky-proxy.ipofmehul.workers.dev"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    /// Timestamp of the last Ctrl+Option press, used to detect double-
    /// press for continuous-listen mode.
    private var lastShortcutPressedAt: Date?

    /// When true, the current recording was triggered by a double-press
    /// and should run continuously (with silence auto-stop) instead of
    /// ending on key release.
    private var isContinuousListenActive: Bool = false

    /// How quickly two presses must happen to count as a double-press.
    private static let doublePressThresholdSeconds: TimeInterval = 0.4

    private var shortcutTransitionCancellable: AnyCancellable?
    private var panelHotkeyCancellable: AnyCancellable?
    private var textModeHotkeyCancellable: AnyCancellable?
    private var wakeWordDetectionCancellable: AnyCancellable?
    private var wakeWordLifecycleOnVoiceStateCancellable: AnyCancellable?
    private var providerReportedTurnEndCancellable: AnyCancellable?
    /// True while the current dictation session was triggered by the
    /// wake word (as opposed to Ctrl+Option). Only wake-word sessions
    /// should auto-close on the provider's turn-end signal — Ctrl+Option
    /// flows end when the user releases the key.
    private var isCurrentDictationSessionFromWakeWord: Bool = false

    /// When the current wake-word-triggered dictation session began.
    /// The provider's end-of-turn signal is ignored during the first
    /// `wakeWordTurnEndGracePeriodSeconds` after this timestamp so a
    /// brief pause between "Hey Koko" and the user's actual command
    /// doesn't close the turn before the command even starts.
    private var currentWakeWordSessionStartedAt: Date?

    /// How long after a wake-word session starts we ignore the
    /// provider's end-of-turn signal. Tuned for the real-world
    /// "Hey Koko, [half-beat], what's on my screen?" cadence.
    private static let wakeWordTurnEndGracePeriodSeconds: TimeInterval = 2.0
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Background task that watches `currentAudioPowerLevel` after a
    /// wake-word-triggered dictation session starts and auto-stops the
    /// session once the user has been silent long enough, since wake
    /// word flows have no press/release gesture to end the turn.
    private var wakeWordSilenceAutoStopTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// Koko's current position in macOS screen coordinates (bottom-left
    /// origin). Updated every frame by `BlueCursorView`'s cursor-tracking
    /// timer and navigation-flight timer so external panels (typed input,
    /// text response) can track the bird's *actual* position — not just
    /// the mouse cursor, which the bird departs from during element-
    /// pointing flights.
    @Published var kokoCurrentScreenPosition: CGPoint = .zero

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-opus-4-7"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    /// User preference for the always-on "Hey Koko" wake word. Off by
    /// default because always-listening is a meaningful escalation of
    /// the app's privacy surface and should be an explicit opt-in.
    /// Persisted so the choice survives restarts.
    @Published private(set) var isWakeWordListeningEnabled: Bool =
        UserDefaults.standard.bool(forKey: "isWakeWordListeningEnabled")

    func setWakeWordListeningEnabled(_ enabled: Bool) {
        isWakeWordListeningEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isWakeWordListeningEnabled")
        refreshWakeWordListenerLifecycle()
    }

    /// Whether a conversation session is currently active. When the
    /// user turns this off, conversation history is summarized to
    /// memory and cleared. Turning it back on starts a fresh session.
    @Published private(set) var isSessionActive: Bool = true

    func setSessionActive(_ active: Bool) {
        if isSessionActive && !active {
            // Session ending — summarize memory, clear history, and
            // put Koko to sleep (hide overlay, stop all listeners).
            summarizeSessionToMemory()
            conversationHistory.removeAll()
            kokoWakeWordListener.stop()
            kokoProactiveObserver.stop()
            kokoNest.stopIdleTimer()
            buddyDictationManager.cancelCurrentDictation()
            currentResponseTask?.cancel()
            currentResponseTask = nil
            elevenLabsTTSClient.stopPlayback()
            textResponseOverlayManager.hide()
            typedInputOverlayManager.hide()
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
            voiceState = .idle
            print("🧠 Session ended — Koko is sleeping")
        } else if !isSessionActive && active {
            // Session starting — wake Koko up.
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            refreshWakeWordListenerLifecycle()
            kokoProactiveObserver.startIfEnabled()
            kokoNest.startIfEnabled()
            print("🧠 New session started — Koko is awake")
        }
        isSessionActive = active
    }

    /// Text-only response mode. When true, Claude's response streams
    /// into a dedicated scrollable text panel next to the bird and
    /// ElevenLabs TTS is skipped entirely. Toggled by the global
    /// Ctrl+Shift+T hotkey or the toggle in the menu bar panel.
    /// Persisted so the choice survives restarts.
    @Published private(set) var isTextOnlyMode: Bool =
        UserDefaults.standard.bool(forKey: "isTextOnlyMode")

    func setTextOnlyMode(_ enabled: Bool) {
        guard isTextOnlyMode != enabled else { return }
        isTextOnlyMode = enabled
        UserDefaults.standard.set(enabled, forKey: "isTextOnlyMode")
        kokoSoundEffects.play(.toggle)
        // Flipping modes mid-response is fine — the current response
        // finishes in whatever mode it started in. New responses
        // pick up the new mode automatically.
        showTextModeToggleFeedback(enabled: enabled)
    }

    /// Briefly shows a small confirmation bubble near the bird that
    /// says "text mode on" / "text mode off" so the toggle has
    /// *some* visible feedback. Without this the hotkey feels like
    /// it does nothing.
    @Published private(set) var textModeToggleFeedbackText: String = ""
    @Published private(set) var isShowingTextModeToggleFeedback: Bool = false
    private var textModeToggleFeedbackHideTask: Task<Void, Never>?

    private func showTextModeToggleFeedback(enabled: Bool) {
        textModeToggleFeedbackText = enabled ? "text mode on" : "text mode off"
        isShowingTextModeToggleFeedback = true
        textModeToggleFeedbackHideTask?.cancel()
        textModeToggleFeedbackHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled, let self else { return }
            self.isShowingTextModeToggleFeedback = false
        }
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindPanelHotkeyTransitions()
        bindTextModeHotkeyTransitions()
        bindWakeWordDetection()
        configureTypedInputOverlay()
        configurePanelPositionProviders()
        configureProactiveObserver()
        configureNest()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            // NOTE: do NOT pre-set `hasShownOverlayBefore` here. The flag
            // is owned by `OverlayWindowManager.showOverlay`, which reads
            // it to decide whether this is a first appearance (triggering
            // Koko's intro flight and welcome bubble). Pre-setting it
            // suppresses the entrance animation.
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            playStartupAudio()
        }

        // Kick off the wake word listener once everything else is wired
        // up. `refreshWakeWordListenerLifecycle` is a no-op when the
        // user hasn't opted in or when permissions are missing.
        refreshWakeWordListenerLifecycle()
        kokoProactiveObserver.startIfEnabled()
        kokoNest.startIfEnabled()
    }

    /// Plays Koko's startup sound stack: a quiet looping BGM plus a short
    /// "kookoo" voice jingle layered on top, timed to coincide with the
    /// sprite's intro flight onto the screen.
    private func playStartupAudio() {
        playStartupBackgroundMusic()
        playStartupKookooIntro()
    }

    private func playStartupBackgroundMusic() {
        stopStartupBackgroundMusic()

        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Koko: ff.mp3 not found in bundle — skipping startup BGM")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            // Deliberately quieter than the onboarding BGM (0.3) — this
            // one is meant to sit *under* the kookoo voice jingle during
            // the intro flight, not linger behind normal app use.
            player.volume = 0.12
            player.numberOfLoops = 0
            player.play()
            self.startupBackgroundMusicPlayer = player

            // Fade the BGM out after ~3s so it caps at roughly the same
            // length as the kookoo voice jingle and then gets out of the
            // way. Without this the track loops or drones on behind
            // every interaction until the app quits.
            startupBackgroundMusicFadeTimer = Timer.scheduledTimer(
                withTimeInterval: 3.0,
                repeats: false
            ) { [weak self] _ in
                self?.fadeOutStartupBackgroundMusic()
            }
        } catch {
            print("⚠️ Koko: Failed to play startup BGM: \(error)")
        }
    }

    private func fadeOutStartupBackgroundMusic() {
        guard let player = startupBackgroundMusicPlayer else { return }

        let fadeStepCount = 20
        let fadeDurationSeconds: Double = 0.6
        let fadeStepInterval = fadeDurationSeconds / Double(fadeStepCount)
        let volumeDecrementPerStep = player.volume / Float(fadeStepCount)
        var fadeStepsRemaining = fadeStepCount

        startupBackgroundMusicFadeTimer?.invalidate()
        startupBackgroundMusicFadeTimer = Timer.scheduledTimer(
            withTimeInterval: fadeStepInterval,
            repeats: true
        ) { [weak self] fadeTimer in
            fadeStepsRemaining -= 1
            player.volume = max(player.volume - volumeDecrementPerStep, 0)

            if fadeStepsRemaining <= 0 {
                fadeTimer.invalidate()
                self?.stopStartupBackgroundMusic()
            }
        }
    }

    private func stopStartupBackgroundMusic() {
        startupBackgroundMusicFadeTimer?.invalidate()
        startupBackgroundMusicFadeTimer = nil
        startupBackgroundMusicPlayer?.stop()
        startupBackgroundMusicPlayer = nil
    }

    private func playStartupKookooIntro() {
        kokoSoundEffects.play(.kookoo)
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        // Summarize the session's conversations into memory before
        // tearing everything down. Runs synchronously since the app
        // is about to terminate — there's no "later" to defer to.
        summarizeSessionToMemory()

        globalPushToTalkShortcutMonitor.stop()
        globalPanelHotkeyMonitor.stop()
        globalTextModeHotkeyMonitor.stop()
        kokoWakeWordListener.stop()
        kokoProactiveObserver.stop()
        kokoNest.stopIdleTimer()
        wakeWordSilenceAutoStopTask?.cancel()
        wakeWordSilenceAutoStopTask = nil
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        typedInputOverlayManager.hide()
        textResponseOverlayManager.hide()
        textModeToggleFeedbackHideTask?.cancel()
        textModeToggleFeedbackHideTask = nil
        transientHideTask?.cancel()
        stopStartupBackgroundMusic()
        startupKookooIntroPlayer?.stop()
        startupKookooIntroPlayer = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        panelHotkeyCancellable?.cancel()
        textModeHotkeyCancellable?.cancel()
        wakeWordDetectionCancellable?.cancel()
        wakeWordLifecycleOnVoiceStateCancellable?.cancel()
        providerReportedTurnEndCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
            globalPanelHotkeyMonitor.start()
            globalTextModeHotkeyMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            globalPanelHotkeyMonitor.stop()
            globalTextModeHotkeyMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }

        // Permissions can flip at any time (user revokes in System
        // Settings, user grants them for the first time, etc.). Make
        // sure the wake word listener reflects the new state so it
        // doesn't crash trying to record without mic access.
        refreshWakeWordListenerLifecycle()
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding or .processing while the
                // response pipeline owns the voice state. The pipeline
                // is responsible for moving state through
                // processing → responding → idle on its own schedule.
                // Without this guard the observer would clobber the
                // pipeline's .processing with .idle the moment the
                // dictation manager finished finalizing, which in turn
                // restarts the wake word listener *before* TTS has
                // even begun playing — and the listener then hears
                // Koko's own voice coming out of the speakers and
                // retriggers on "coco" / "koko" mentions in the reply.
                if self.currentResponseTask != nil {
                    // Still mirror listening-state transitions *into*
                    // the pipeline window so the waveform shows up
                    // while the user is mid-press, but never flip out
                    // of pipeline-managed states.
                    if isRecording {
                        self.voiceState = .listening
                    }
                    return
                }

                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    self.scheduleTransientHideIfNeeded()
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    /// Wires Option+Space to toggle the inline typed-input overlay that
    /// sits next to the bird. Previously this hotkey opened the menu bar
    /// panel; now it's a lightweight speech-bubble-style Spotlight field
    /// that lives on top of whatever app the user is currently using.
    private func bindPanelHotkeyTransitions() {
        panelHotkeyCancellable = globalPanelHotkeyMonitor
            .panelHotkeyPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handlePanelHotkeyPressed()
            }
    }

    /// Wires Ctrl+Shift+T to flip text-only response mode on and off.
    /// The hotkey itself is intentionally minimal — just invert the
    /// flag, persist it, and show a brief toast. The response pipeline
    /// reads `isTextOnlyMode` on each new response.
    private func bindTextModeHotkeyTransitions() {
        textModeHotkeyCancellable = globalTextModeHotkeyMonitor
            .textModeHotkeyPressedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.setTextOnlyMode(!self.isTextOnlyMode)
            }
    }

    /// Hooks the typed input overlay's submit callback up to the shared
    /// voice/typed command pipeline so a typed prompt goes through the
    /// exact same screenshot + Claude + TTS + pointing flow.
    private func configureTypedInputOverlay() {
        typedInputOverlayManager.onSubmit = { [weak self] submittedText in
            self?.submitTypedCommand(submittedText)
        }
    }

    /// Gives both overlay panel managers a closure that returns Koko's
    /// real-time screen position (published by `BlueCursorView` every
    /// frame). The panels use this instead of `NSEvent.mouseLocation`
    /// so they follow the bird even when it flies away from the cursor
    /// to point at a UI element.
    private func configurePanelPositionProviders() {
        let positionProvider: () -> CGPoint = { [weak self] in
            self?.kokoCurrentScreenPosition ?? NSEvent.mouseLocation
        }
        typedInputOverlayManager.kokoScreenPositionProvider = positionProvider
        textResponseOverlayManager.kokoScreenPositionProvider = positionProvider
    }

    /// Wires the proactive observer's trigger to a screenshot + Claude
    /// observation flow. Uses text-only mode for the response since
    /// proactive comments should appear quietly, not spoken aloud.
    private func configureProactiveObserver() {
        kokoProactiveObserver.onObservationTriggered = { [weak self] in
            self?.performProactiveObservation()
        }
    }

    /// Wires the nest callbacks. The actual flight animation
    /// is triggered via a published position that BlueCursorView
    /// reads — similar to element pointing but without the bezier arc.
    private func configureNest() {
        kokoNest.onShouldNest = { [weak self] targetCornerPosition in
            guard let self else { return }
            // Store the perch target so BlueCursorView can fly there.
            self.nestTargetScreenPosition = targetCornerPosition
            self.isNesting = true
            print("🪹 Koko nest: flying to corner (\(Int(targetCornerPosition.x)), \(Int(targetCornerPosition.y)))")
        }
        kokoNest.onShouldReturnFromNest = { [weak self] in
            guard let self else { return }
            self.isNesting = false
            self.nestTargetScreenPosition = nil
            print("🪹 Koko nest: returning to cursor")
        }
    }

    /// Performs a proactive screen observation — takes a screenshot
    /// and sends it to Claude with the observation prompt. Always
    /// uses text-only display (no TTS) so it's non-intrusive.
    private func performProactiveObservation() {
        // Don't interrupt an active interaction.
        guard !buddyDictationManager.isDictationInProgress else {
            print("👁️ Proactive observation skipped: dictation in progress")
            return
        }
        guard currentResponseTask == nil else {
            print("👁️ Proactive observation skipped: response task in flight")
            return
        }
        guard hasCompletedOnboarding, allPermissionsGranted else {
            print("👁️ Proactive observation skipped: permissions missing")
            return
        }
        print("👁️ Proactive observation: starting")

        // If nested, save the nest position so the bird can return
        // there after the observation (and optional pointing) finishes.
        // Pause the idle timer without returning to cursor — the bird
        // stays at its nest unless the observation points it somewhere.
        if isNesting, let nestPos = nestTargetScreenPosition {
            savedNestPosition = nestPos
            kokoNest.pauseIdleTimerForObservation()
        }

        kokoSoundEffects.play(.think)

        // Force text-only for proactive observations regardless of
        // the user's text-mode toggle — spoken unprompted comments
        // would be jarring.
        textResponseOverlayManager.beginStreamingResponse()
        typedInputOverlayManager.hide()

        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            self.voiceState = .processing

            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Inject memory if enabled.
                var observationPrompt = KokoProactiveObserver.observationSystemPrompt
                let memoryContent = self.kokoMemoryManager.loadMemoryForPrompt()
                if !memoryContent.isEmpty {
                    observationPrompt += "\n\nyour memory of past interactions:\n\(memoryContent)"
                }

                let (fullResponseText, _) = try await self.claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: observationPrompt,
                    conversationHistory: [],
                    userPrompt: "take a look at my screen and share one quick thought.",
                    onTextChunk: { [weak self] accumulatedText in
                        guard let self else { return }
                        let cleanedText = Self.stripPointingTagFromStreamingText(accumulatedText)
                        Task { @MainActor in
                            if self.voiceState != .responding {
                                self.voiceState = .responding
                            }
                            self.textResponseOverlayManager.updateStreamingResponse(text: cleanedText)
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let observationText = Self.stripPointingTagFromStreamingText(parseResult.spokenText)

                // Handle pointing if the observation references a UI element.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                    let appKitY = displayHeight - displayLocalY

                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    // Use the POINT tag's short label (e.g. "error
                    // message") for the bubble, not the full observation
                    // text — that's already in the text response panel.
                    self.detectedElementBubbleText = parseResult.elementLabel
                    self.detectedElementScreenLocation = globalLocation
                    self.detectedElementDisplayFrame = displayFrame
                    self.kokoSoundEffects.play(.point)
                }

                self.textResponseOverlayManager.updateStreamingResponse(text: observationText)
                self.textResponseOverlayManager.finishStreamingResponse()

                // No memory save for proactive observations — they're
                // noise. Only user-initiated exchanges get remembered.

                self.kokoSoundEffects.play(.done)
            } catch is CancellationError {
                self.textResponseOverlayManager.hide()
            } catch {
                self.kokoSoundEffects.play(.error)
                self.textResponseOverlayManager.updateStreamingResponse(
                    text: "couldn't take a look right now."
                )
                self.textResponseOverlayManager.finishStreamingResponse()
            }

            if !Task.isCancelled {
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()

                // If nest is enabled and was due, perch now
                if self.savedNestPosition != nil {
                    // Was nesting before the observation — isNesting and
                    // nestTargetScreenPosition are still set (we used
                    // pauseIdleTimerForObservation, not reset), so the
                    // bird stays at the nest. If there's an in-flight
                    // pointing animation, DO NOT clear savedNestPosition
                    // here — startFlyingBackToCursor needs it to fly
                    // the bird directly back to the nest after holding.
                    // savedNestPosition is cleared in the bezier flight
                    // completion handler when the bird lands at nest.
                    if self.detectedElementScreenLocation == nil {
                        // No pointing happened — safe to clear now.
                        self.savedNestPosition = nil
                    }
                    self.kokoNest.resumeIdleTimerAfterObservation()
                } else if self.kokoNest.isEnabled && !self.isNesting {
                    // Wasn't nesting — observe then nest after a delay.
                    try? await Task.sleep(for: .milliseconds(2000))
                    if !Task.isCancelled && !self.buddyDictationManager.isDictationInProgress {
                        self.kokoNest.triggerNestNow()
                    }
                }
            }
            self.currentResponseTask = nil
        }
    }

    /// Published state for nesting so BlueCursorView can read it.
    @Published var isNesting: Bool = false
    @Published var nestTargetScreenPosition: CGPoint?

    /// Saved nest position when a proactive observation fires while
    /// nesting. After the observation (and optional pointing) finishes,
    /// the bird returns to this position instead of the cursor.
    @Published var savedNestPosition: CGPoint?

    /// Resets all interaction-dependent timers — called on every user
    /// command (PTT, typed, wake word) so proactive observations and
    /// nest countdowns restart from zero.
    private func resetInteractionTimers() {
        kokoProactiveObserver.resetTimer()
        kokoNest.resetIdleTimer()
    }

    // MARK: - Wake Word

    /// Subscribe to the on-device "Hey Koko" wake word listener and
    /// route detections into the same screenshot + Claude + TTS
    /// pipeline push-to-talk uses. Also observe `voiceState` so the
    /// listener can cleanly resume once a full response cycle
    /// completes (transcription + Claude + TTS + pointing).
    private func bindWakeWordDetection() {
        wakeWordDetectionCancellable = kokoWakeWordListener
            .wakeWordDetectedPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleWakeWordDetection()
            }

        wakeWordLifecycleOnVoiceStateCancellable = $voiceState
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] newVoiceState in
                guard let self, newVoiceState == .idle else { return }
                // Reset session flags as soon as we're idle so they
                // don't leak into the next session's classification.
                self.isCurrentDictationSessionFromWakeWord = false
                self.currentWakeWordSessionStartedAt = nil
                self.isContinuousListenActive = false
                self.refreshWakeWordListenerAfterTTSPlayback()
            }

        providerReportedTurnEndCancellable = buddyDictationManager
            .providerReportedTurnEndPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Only close the session automatically when the wake
                // word triggered it. Ctrl+Option push-to-talk already
                // ends on the user's key release — we don't want a
                // transient early end-of-turn to cut the user off
                // mid-command on that path.
                guard self.isCurrentDictationSessionFromWakeWord else { return }
                guard self.buddyDictationManager.isRecordingFromKeyboardShortcut else { return }

                // Grace period: ignore end-of-turn signals that arrive
                // in the first couple of seconds. AssemblyAI will
                // happily declare the turn done during the tiny pause
                // between "Hey Koko" and the user's actual command,
                // which would slam the session closed before they've
                // said anything useful.
                if let sessionStartedAt = self.currentWakeWordSessionStartedAt,
                   Date().timeIntervalSince(sessionStartedAt) < Self.wakeWordTurnEndGracePeriodSeconds {
                    print("🪺 Koko wake word: ignoring early end-of-turn (grace period)")
                    return
                }

                print("🪺 Koko wake word: AssemblyAI reported end-of-turn — stopping")
                self.wakeWordSilenceAutoStopTask?.cancel()
                self.wakeWordSilenceAutoStopTask = nil
                self.buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            }
    }

    /// Waits for any in-flight TTS playback to finish, then refreshes
    /// the wake word listener lifecycle. Called whenever `voiceState`
    /// returns to `.idle` so the listener never resumes while Koko's
    /// own voice is coming out the speakers — otherwise the TTS could
    /// echo-trigger the wake phrase back at us.
    ///
    /// After playback ends, waits an additional short grace period so
    /// any room echo or speaker-bleed tail can decay before the
    /// microphone starts listening again. Without this, immediately
    /// restarting the listener can still pick up the last ~200ms of
    /// Koko's final syllable as it reverberates in the room.
    private func refreshWakeWordListenerAfterTTSPlayback() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Give the audio player a brief moment to actually start
            // playing before we decide "it's not playing, refresh now".
            // Without this, a race where voiceState flips to .idle a
            // tick before `player.play()` lands would see isPlaying
            // == false and restart the listener too early.
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }

            while self.elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }

            // Post-playback echo grace period.
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }

            // Bail if something kicked off another TTS during the
            // grace period (response interrupted, new command etc.).
            guard !self.elevenLabsTTSClient.isPlaying else { return }

            self.refreshWakeWordListenerLifecycle()
        }
    }

    /// Starts or stops the wake word listener based on whether the
    /// user has opted in AND we're in a state where taking over the
    /// mic would be safe (onboarded, permissions granted, no other
    /// voice flow currently mid-session).
    ///
    /// Safe to call any time — if conditions haven't changed, this
    /// is a no-op thanks to `start()`'s internal `isRunning` guard.
    func refreshWakeWordListenerLifecycle() {
        let shouldBeListening = isWakeWordListeningEnabled
            && hasCompletedOnboarding
            && allPermissionsGranted
            && !buddyDictationManager.isDictationInProgress
            && !showOnboardingVideo
            // Never listen while Koko's own TTS is coming out the
            // speakers — otherwise the mic picks up Koko saying
            // "koko" in its reply and re-triggers the wake word.
            && !elevenLabsTTSClient.isPlaying
            // Never listen mid-response — the pipeline owns the mic
            // and the wake listener fighting for the input node
            // would either be useless (no detection while the user
            // is waiting on a response) or actively harmful
            // (capturing TTS audio).
            && currentResponseTask == nil

        if shouldBeListening {
            kokoWakeWordListener.start()
        } else {
            kokoWakeWordListener.stop()
        }
    }

    private func handleWakeWordDetection() {
        kokoSoundEffects.play(.wake)

        // Immediately free the mic so the main dictation pipeline can
        // take it over without fighting CoreAudio for the input node.
        kokoWakeWordListener.stop()

        // Return from nest immediately so the bird starts swooping
        // back the moment the user speaks, not seconds later when
        // the transcript is submitted.
        kokoNest.resetIdleTimer()

        // Mark this session as wake-word-originated so the
        // providerReportedTurnEnd subscriber knows it's allowed to
        // auto-close on the native end-of-turn signal. The start
        // timestamp feeds the grace-period guard that ignores
        // spurious end-of-turn signals fired during the half-beat
        // pause between "Hey Koko" and the user's actual command.
        isCurrentDictationSessionFromWakeWord = true
        currentWakeWordSessionStartedAt = Date()

        // Reject the detection if another voice flow is already in
        // motion, the onboarding video is up, or permissions dropped
        // in the time between enabling the listener and this callback.
        guard !buddyDictationManager.isDictationInProgress else { return }
        guard !showOnboardingVideo else { return }
        guard hasCompletedOnboarding, allPermissionsGranted else { return }

        // Same pre-flight as Ctrl+Option press — cancel pending hides,
        // bring the overlay back if it was in transient-hidden mode,
        // dismiss the menu bar panel, and clear any in-flight response.
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        textResponseOverlayManager.hide()
        clearDetectedElementLocation()

        ClickyAnalytics.trackPushToTalkStarted()

        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = Task {
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts are hidden (waveform-only UI).
                },
                submitDraftText: { [weak self] finalTranscript in
                    self?.lastTranscript = finalTranscript
                    print("🗣️ Koko received wake-word transcript: \(finalTranscript)")
                    ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                    self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                }
            )
            await self.startWakeWordSilenceAutoStop()
        }
    }

    /// Polls `currentAudioPowerLevel` after a wake-word-triggered
    /// dictation session starts and hard-stops the session once the
    /// user has been silent long enough. Wake-word flows have no
    /// press/release gesture to end the turn, so this is what closes
    /// it out.
    ///
    /// Silence detection uses a *relative* peak-tracking heuristic
    /// rather than a fixed threshold: ambient noise in a typical room
    /// can easily sit at 0.03–0.06 on this scale, so a fixed floor
    /// either cuts people off mid-sentence or never fires at all.
    /// Instead we remember the loudest level observed during the
    /// session and declare silence when the current level drops to
    /// roughly 15% of that peak. The peak decays slowly so a single
    /// brief loud syllable doesn't lock the threshold at an unreachable
    /// value.
    ///
    /// Backstops:
    /// - A 1.0s warm-up at the start so a brisk "Hey Koko" doesn't
    ///   immediately count as silence before the command lands.
    /// - A hard 15s maximum turn length so the session can't get
    ///   stuck open even if silence detection totally fails.
    /// - Starts the silence monitor only *after* confirming the
    ///   dictation manager has actually flipped into "recording"
    ///   state, so a race with `startPushToTalkFromKeyboardShortcut`
    ///   can't terminate the monitor before it begins.
    private func startWakeWordSilenceAutoStop() async {
        wakeWordSilenceAutoStopTask?.cancel()
        wakeWordSilenceAutoStopTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let warmUpDurationSeconds: Double = 1.0
            let requiredConsecutiveSilenceSeconds: Double = 1.2
            let silencePollIntervalMilliseconds: UInt64 = 80
            // Typical laptop mic ambient noise lands around 0.05–0.10
            // on this boosted RMS scale. A floor below that range
            // never fires in real rooms, which is exactly what was
            // happening — 0.035 was always above ambient, so the
            // detector saw "not silent" forever.
            let absoluteSilenceFloor: CGFloat = 0.10
            // Silence fires when current is below 30% of the observed
            // peak (widened from 15% so louder speakers don't lock
            // the bar at an unreachable level).
            let relativeSilenceFractionOfPeak: CGFloat = 0.30
            // Decay the peak faster (4.5% per 80ms ≈ 45% per second)
            // so the relative threshold catches up within a second of
            // the user going quiet.
            let peakDecayFactorPerPoll: CGFloat = 0.955
            let maximumTurnDurationSeconds: Double = 15.0

            // Wait for the dictation manager to actually enter the
            // recording state. There's a brief async window between
            // `startPushToTalkFromKeyboardShortcut` returning and the
            // first audio buffer landing, and without this guard the
            // monitor can race past the recording-state check and
            // terminate itself before it's done anything useful.
            var dictationStartWaitAttempts = 0
            while !Task.isCancelled
                && !self.buddyDictationManager.isRecordingFromKeyboardShortcut
                && dictationStartWaitAttempts < 40 {
                try? await Task.sleep(nanoseconds: 50 * 1_000_000)
                dictationStartWaitAttempts += 1
            }
            guard self.buddyDictationManager.isRecordingFromKeyboardShortcut else {
                print("🪺 Koko wake word: dictation never started — bailing silence monitor")
                return
            }

            // Warm-up so the "Hey Koko" + the lead-in to the real
            // command isn't mistaken for silence.
            try? await Task.sleep(for: .milliseconds(UInt64(warmUpDurationSeconds * 1000)))

            let sessionStartedAt = Date()
            var observedPeakPowerLevel: CGFloat = 0
            var firstSilenceObservedAt: Date?

            print("🪺 Koko wake word: silence monitor active")

            while !Task.isCancelled {
                guard self.buddyDictationManager.isRecordingFromKeyboardShortcut else {
                    print("🪺 Koko wake word: dictation ended before silence detector fired")
                    break
                }

                // Hard cap — if the silence detector totally misfires,
                // the session still ends after 15 seconds so Koko
                // never becomes a permanent hot mic.
                if Date().timeIntervalSince(sessionStartedAt) >= maximumTurnDurationSeconds {
                    print("🪺 Koko wake word: hit maximum turn length (\(maximumTurnDurationSeconds)s) — force-stopping")
                    self.buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                    break
                }

                let currentAudioPowerLevel = self.buddyDictationManager.currentAudioPowerLevel

                // Track the loudest level the user has produced during
                // this turn and let it decay gently each poll so a
                // single loud peak doesn't permanently set the bar
                // above what "silence" can reach.
                if currentAudioPowerLevel > observedPeakPowerLevel {
                    observedPeakPowerLevel = currentAudioPowerLevel
                } else {
                    observedPeakPowerLevel *= peakDecayFactorPerPoll
                }

                // "Silence" = both (a) well below the user's recent
                // speaking peak, and (b) below an absolute floor so
                // mere ambient hiss doesn't count as speech.
                let relativeSilenceThreshold = observedPeakPowerLevel * relativeSilenceFractionOfPeak
                let silenceThreshold = max(absoluteSilenceFloor, relativeSilenceThreshold)
                let isCurrentlySilent = currentAudioPowerLevel < silenceThreshold

                let now = Date()
                if isCurrentlySilent {
                    if firstSilenceObservedAt == nil {
                        firstSilenceObservedAt = now
                    } else if let silenceStartedAt = firstSilenceObservedAt,
                              now.timeIntervalSince(silenceStartedAt) >= requiredConsecutiveSilenceSeconds {
                        print(String(
                            format: "🪺 Koko wake word: auto-stopping (silent %.1fs, peak %.3f, floor %.3f)",
                            requiredConsecutiveSilenceSeconds,
                            observedPeakPowerLevel,
                            silenceThreshold
                        ))
                        self.buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                        break
                    }
                } else {
                    firstSilenceObservedAt = nil
                }

                try? await Task.sleep(nanoseconds: silencePollIntervalMilliseconds * 1_000_000)
            }
        }
    }

    private func handlePanelHotkeyPressed() {
        // Don't fight with the push-to-talk flow — if the user is already
        // speaking, the hotkey is probably a misfire from the ctrl+option
        // chord rather than a deliberate "open the typed input" action.
        guard !buddyDictationManager.isDictationInProgress else { return }
        // Respect the same onboarding/permissions gating used elsewhere so
        // the user can't type prompts before the app is actually usable.
        guard hasCompletedOnboarding, allPermissionsGranted else { return }

        // Dismiss the text response panel so the two don't overlap.
        textResponseOverlayManager.hide()
        typedInputOverlayManager.toggle()
    }

    /// Public entry point for the Spotlight-style typed command field in the
    /// menu bar panel. Runs the same pre-flight as push-to-talk (cancel any
    /// in-flight response, bring the overlay back if hidden, dismiss the
    /// panel), then hands the typed text to the standard Claude + screenshot
    /// + TTS + element-pointing pipeline.
    func submitTypedCommand(_ typedCommandText: String) {
        let trimmedTypedCommand = typedCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTypedCommand.isEmpty else { return }
        guard hasCompletedOnboarding, allPermissionsGranted else { return }

        // Return from nest immediately on typed command.
        kokoNest.resetIdleTimer()

        // Cancel any pending transient hide so the overlay stays visible
        // through the full response cycle.
        transientHideTask?.cancel()
        transientHideTask = nil

        // If the cursor overlay is hidden (transient-cursor mode), bring it
        // back for the duration of this interaction — matches the push-to-talk
        // path in `handleShortcutTransition(.pressed)`.
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Dismiss the menu bar panel so the response renders in the full-screen
        // overlay without being covered.
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Cancel any in-progress response and TTS from a previous utterance.
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        textResponseOverlayManager.hide()
        clearDetectedElementLocation()

        lastTranscript = trimmedTypedCommand
        ClickyAnalytics.trackUserMessageSent(transcript: trimmedTypedCommand)
        sendTranscriptToClaudeWithScreenshot(transcript: trimmedTypedCommand)
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // If continuous listen is active, pressing again STOPS it.
            if isContinuousListenActive {
                isContinuousListenActive = false
                wakeWordSilenceAutoStopTask?.cancel()
                wakeWordSilenceAutoStopTask = nil
                ClickyAnalytics.trackPushToTalkReleased()
                pendingKeyboardShortcutStartTask?.cancel()
                pendingKeyboardShortcutStartTask = nil
                buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
                lastShortcutPressedAt = nil
                return
            }

            guard !buddyDictationManager.isDictationInProgress else { return }
            guard !showOnboardingVideo else { return }

            // Detect double-press: if two presses within the threshold,
            // enter continuous-listen mode (toggle on/off). Otherwise
            // it's a normal hold-to-talk.
            let now = Date()
            let isDoublePress: Bool
            if let lastPressAt = lastShortcutPressedAt,
               now.timeIntervalSince(lastPressAt) < Self.doublePressThresholdSeconds {
                isDoublePress = true
                lastShortcutPressedAt = nil
            } else {
                isDoublePress = false
                lastShortcutPressedAt = now
            }

            // Common pre-flight for both modes.
            kokoWakeWordListener.stop()
            wakeWordSilenceAutoStopTask?.cancel()
            wakeWordSilenceAutoStopTask = nil
            isCurrentDictationSessionFromWakeWord = false
            currentWakeWordSessionStartedAt = nil

            // Return from nest immediately so the bird starts
            // swooping back the moment Ctrl+Option is pressed.
            kokoNest.resetIdleTimer()

            transientHideTask?.cancel()
            transientHideTask = nil

            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            currentResponseTask?.cancel()
            currentResponseTask = nil
            elevenLabsTTSClient.stopPlayback()
            textResponseOverlayManager.hide()
            clearDetectedElementLocation()

            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }

            kokoSoundEffects.play(.listen)
            ClickyAnalytics.trackPushToTalkStarted()

            if isDoublePress {
                isContinuousListenActive = true
                print("🎙️ Continuous listen: ON (double-press detected)")
            }

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        let trimmedTranscript = finalTranscript
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        // Don't send empty transcripts to Claude — this
                        // happens when the user releases the shortcut
                        // before saying anything. Just go back to idle.
                        guard !trimmedTranscript.isEmpty else {
                            print("🎙️ Empty transcript — skipping response")
                            return
                        }

                        self.lastTranscript = trimmedTranscript
                        print("🗣️ Companion received transcript: \(trimmedTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: trimmedTranscript)
                        self.sendTranscriptToClaudeWithScreenshot(transcript: trimmedTranscript)
                    }
                )

                // In continuous-listen mode, start the silence auto-stop
                // so the session ends naturally when the user stops
                // speaking (same system as wake-word flows).
                if self.isContinuousListenActive {
                    await self.startWakeWordSilenceAutoStop()
                }
            }

        case .released:
            // In continuous-listen mode, releasing the keys is a no-op —
            // the session stays open until the user presses again or
            // silence auto-stop fires.
            if isContinuousListenActive {
                return
            }

            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()

        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're koko, a friendly always-on companion (a little pixel-art koyal bird) that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// Builds the full system prompt by appending memory context (if
    /// enabled) to the base voice-response prompt.
    private func buildSystemPromptWithMemory() -> String {
        var systemPrompt = Self.companionVoiceResponseSystemPrompt
        let memoryContent = kokoMemoryManager.loadMemoryForPrompt()
        if !memoryContent.isEmpty {
            systemPrompt += "\n\nyour memory of past interactions with this user:\n\(memoryContent)"
        }
        return systemPrompt
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        resetInteractionTimers()
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        // Snapshot the mode at the start of the turn so a mid-response
        // toggle doesn't change how this particular response ends.
        let isThisResponseTextOnly = isTextOnlyMode

        // In text-only mode, open the scrollable text panel immediately
        // in a "waiting for first chunk" state so the user gets instant
        // acknowledgement that Koko is working on it.
        if isThisResponseTextOnly {
            // Dismiss the typed input so the two panels don't overlap.
            typedInputOverlayManager.hide()
            textResponseOverlayManager.beginStreamingResponse()
        } else {
            textResponseOverlayManager.hide()
        }

        currentResponseTask = Task { [weak self] in
            guard let self else { return }

            // Stay in processing (spinner) state — no streaming text displayed
            self.voiceState = .processing
            self.kokoSoundEffects.play(.think)

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = self.conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await self.claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: self.buildSystemPromptWithMemory(),
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] accumulatedText in
                        guard let self, isThisResponseTextOnly else { return }
                        let cleanedText = Self.stripPointingTagFromStreamingText(accumulatedText)
                        Task { @MainActor in
                            // Switch to .responding the moment the first
                            // chunk arrives so the talking animation plays
                            // while text streams in — Koko "speaks" the
                            // text even though there's no audio.
                            if self.voiceState != .responding {
                                self.voiceState = .responding
                            }
                            self.textResponseOverlayManager.updateStreamingResponse(text: cleanedText)
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    self.kokoSoundEffects.play(.point)
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                // Memory is saved once per session (on quit), not
                // per-exchange. conversationHistory holds everything
                // Claude needs to summarize the session.

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                if isThisResponseTextOnly {
                    // Text-only mode: the onTextChunk callback already
                    // set voiceState = .responding and streamed text
                    // into the panel. Push the final cleaned version
                    // to guarantee completeness, then mark done.
                    self.textResponseOverlayManager.updateStreamingResponse(text: spokenText)
                    self.textResponseOverlayManager.finishStreamingResponse()
                    // voiceState is already .responding from onTextChunk
                } else if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Voice mode: play the response via ElevenLabs TTS.
                    // Keep the spinner (processing state) until the
                    // audio actually starts playing, then switch to
                    // responding and HOLD that state until playback
                    // finishes — otherwise the talking animation would
                    // flash for one frame and then snap to idle.
                    do {
                        try await self.elevenLabsTTSClient.speakText(spokenText)
                        self.voiceState = .responding

                        // Wait for TTS playback to actually finish so
                        // the talking animation plays for the full
                        // duration of Koko's reply.
                        while self.elevenLabsTTSClient.isPlaying {
                            guard !Task.isCancelled else { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    } catch is CancellationError {
                        // User interrupted — fall through to idle
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        self.speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                if isThisResponseTextOnly {
                    self.textResponseOverlayManager.hide()
                }
            } catch {
                self.kokoSoundEffects.play(.error)
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                if isThisResponseTextOnly {
                    self.textResponseOverlayManager.updateStreamingResponse(
                        text: "couldn't reach claude. try again in a moment."
                    )
                    self.textResponseOverlayManager.finishStreamingResponse()
                } else {
                    self.speakCreditsErrorFallback()
                }
            }

            if !Task.isCancelled {
                self.kokoSoundEffects.play(.done)
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }

            // Critical: nil out the task reference so
            // refreshWakeWordListenerLifecycle sees
            // currentResponseTask == nil and can restart the
            // listener. Without this, the wake word listener
            // stays dead after the first response.
            self.currentResponseTask = nil
        }
    }

    /// Summarizes the entire session's conversation history into a
    /// few short bullet points and appends them to memory.md. Called
    /// once in `stop()` when the app is quitting — NOT per-exchange.
    /// Uses a synchronous semaphore so the summary completes before
    /// the process terminates.
    private func summarizeSessionToMemory() {
        guard kokoMemoryManager.isEnabled else { return }
        guard !conversationHistory.isEmpty else { return }

        // Build a condensed transcript for Claude to summarize.
        let sessionTranscript = conversationHistory.map { exchange in
            "User: \(exchange.userTranscript.prefix(100))\nKoko: \(exchange.assistantResponse.prefix(150))"
        }.joined(separator: "\n---\n")

        let summaryPrompt = """
        Here is a session of \(conversationHistory.count) exchange(s) between a user and their bird companion Koko:

        \(sessionTranscript)

        Summarize what Koko learned about the user in 1-3 bullet points. Each bullet should be a short fact (under 15 words) worth remembering for next time. Focus on preferences, projects, or recurring topics — not transient questions. If nothing worth remembering, respond with just "skip".
        """

        // Use a semaphore to block until the summary completes,
        // because applicationWillTerminate doesn't wait for async
        // work to finish.
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached { [weak self] in
            guard let self else { semaphore.signal(); return }
            do {
                let claudeAPI = await self.claudeAPI
                let (summaryText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: [],
                    systemPrompt: "You are a memory summarizer. Output ONLY the bullet points, nothing else. Each line starts with '- '. No quotes, no preamble, no headers.",
                    conversationHistory: [],
                    userPrompt: summaryPrompt,
                    onTextChunk: { _ in }
                )

                let cleanedSummary = summaryText
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if cleanedSummary.lowercased() != "skip" && !cleanedSummary.isEmpty {
                    await MainActor.run {
                        // Append each bullet as a separate line.
                        let lines = cleanedSummary.components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        for line in lines {
                            self.kokoMemoryManager.appendSummary(line.hasPrefix("- ") ? String(line.dropFirst(2)) : line)
                        }
                    }
                    print("🧠 Session memory saved (\(cleanedSummary.components(separatedBy: "\n").count) items)")
                }
            } catch {
                print("⚠️ Session memory summary failed: \(error.localizedDescription)")
            }
            semaphore.signal()
        }

        // Wait up to 10 seconds for the summary to complete before
        // the process terminates. If Claude is slow or unreachable,
        // we give up and the session's conversations are lost from
        // memory (but still in the in-session history if the app
        // is re-opened quickly).
        _ = semaphore.wait(timeout: .now() + 10)
    }

    /// Removes a trailing `[POINT:...]` tag (and anything after it) from
    /// streaming response text so the text-mode panel never flashes the
    /// pointing metadata to the user mid-stream.
    private static func stripPointingTagFromStreamingText(_ streamingText: String) -> String {
        // Remove [POINT:...] tags wherever they appear — beginning,
        // middle, or end of the text. Claude doesn't always put them
        // at the end.
        let stripped = streamingText.replacingOccurrences(
            of: "\\[POINT:[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.elementLabel
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
