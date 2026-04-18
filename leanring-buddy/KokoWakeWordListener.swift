//
//  KokoWakeWordListener.swift
//  leanring-buddy
//
//  Always-on "Hey Koko" wake word detection. Runs entirely on-device
//  via `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
//  so no audio ever leaves the machine, and audio buffers are discarded
//  as fast as they're processed (the listener never retains them).
//
//  This is the interim implementation — Porcupine will drop in behind
//  the same `KokoWakeWordListener` protocol once the license is active,
//  at which point `CompanionManager` can swap providers without any
//  downstream changes.
//

import AVFoundation
import Combine
import Foundation
import Speech

/// Common surface every wake-word backend (Apple Speech today,
/// Porcupine tomorrow) conforms to so `CompanionManager` can swap
/// implementations behind a single type.
protocol KokoWakeWordListener: AnyObject {
    /// Fires once each time the user says "Hey Koko". Consumers should
    /// immediately call `stop()` to free the microphone for the
    /// downstream dictation pipeline, and then call `start()` again
    /// once that pipeline finishes.
    var wakeWordDetectedPublisher: PassthroughSubject<Void, Never> { get }

    func start()
    func stop()
}

/// Wake-word listener backed by Apple's on-device `SFSpeechRecognizer`.
///
/// Strategy:
/// - Owns its own `AVAudioEngine` so it can be stopped cleanly when
///   the main dictation pipeline needs the microphone.
/// - Streams audio into an `SFSpeechAudioBufferRecognitionRequest` with
///   `requiresOnDeviceRecognition = true`, so no audio ever leaves
///   the device — audio buffers are consumed by the recognition task
///   and immediately discarded.
/// - Watches partial transcripts for a whitelist of phonetic variants
///   of "hey koko". Apple Speech doesn't spell the name consistently
///   (it's not in its lexicon), so we accept "hey coco", "hey kogo",
///   etc. as equivalent matches.
/// - Preemptively restarts the recognition task every ~50 seconds to
///   stay under the macOS per-task recognition cap (~60s), which
///   otherwise silently stops delivering results.
@MainActor
final class AppleSpeechKokoWakeWordListener: NSObject, KokoWakeWordListener {
    let wakeWordDetectedPublisher = PassthroughSubject<Void, Never>()

    /// Full two-word phrase variants Apple Speech regularly produces
    /// when the user says "Hey Koko". Apple Speech has no entry for
    /// "Koko" in its lexicon, so whitelisting the spellings it
    /// *actually* emits avoids false negatives.
    ///
    /// Transcripts are normalized (lowercased, punctuation stripped,
    /// whitespace collapsed) before matching, so the entries here
    /// don't need to worry about commas, apostrophes, or extra spaces.
    private static let wakePhraseVariants: [String] = [
        "hey koko",
        "hey coco",
        "hey cocoa",
        "hey coca",
        "hey koca",
        "hey kogo",
        "hey kolo",
        "hey kokoa",
        "hey cocoh",
        "hey kokoh",
        "hey ko ko",
        "hey co co",
        "a koko",
        "a coco",
        "okay koko",
        "okay coco",
        "hi koko",
        "hi coco",
        "yo koko",
        "yo coco",
        "hay koko",
        "hay coco"
    ]

    /// Standalone "Koko-like" tokens that also count as a wake signal
    /// on their own, without requiring a leading "hey". These are
    /// words that essentially never appear in normal dictation
    /// ("koko" is not a real English word; "coco" is rare enough to
    /// tolerate the occasional false positive) so accepting them
    /// standalone dramatically improves recognition reliability for
    /// users who mumble the "hey" or whose accent doesn't land on it.
    private static let standaloneKokoLikeTokens: [String] = [
        "koko",
        "kokoa",
        "kokoh",
        "kogo",
        "kolo",
        "koca",
        "coco",
        "cocoa",
        "cocoh",
        "coca"
    ]

    /// Apple's recognition task is capped around 60s on macOS — after
    /// that it silently stops delivering results. We restart well
    /// before the cap to avoid that failure mode.
    private static let recognitionTaskRestartIntervalSeconds: TimeInterval = 50

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()

    private var activeRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeRecognitionTask: SFSpeechRecognitionTask?
    private var taskRestartTimer: Timer?
    private var isRunning = false

    /// Most recently logged partial transcript, used to dedupe the
    /// diagnostic log output so we don't spam the console with
    /// dozens of identical partial updates per second.
    private var lastLoggedPartialTranscript: String = ""

    deinit {
        // Running the full teardown off the main actor would be nice,
        // but deinit runs synchronously and we can't hop actors here.
        // The worst case is a dangling Timer + audio tap briefly
        // outliving the instance, both of which are harmless.
    }

    func start() {
        guard !isRunning else { return }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            print("⚠️ Koko wake word: SFSpeechRecognizer is unavailable")
            return
        }

        let currentSpeechAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        switch currentSpeechAuthorizationStatus {
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] newAuthorizationStatus in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if newAuthorizationStatus == .authorized {
                        self.start()
                    } else {
                        print("⚠️ Koko wake word: speech recognition permission denied")
                    }
                }
            }
            return
        case .authorized:
            break
        case .denied, .restricted:
            print("⚠️ Koko wake word: speech recognition not authorized (\(currentSpeechAuthorizationStatus.rawValue))")
            return
        @unknown default:
            print("⚠️ Koko wake word: unknown speech authorization status")
            return
        }

        isRunning = true
        startRecognitionTask()
        print("🪺 Koko wake word: listening for 'Hey Koko'")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tearDownRecognitionTask(stoppingAudioEngine: true)
        print("🪺 Koko wake word: stopped listening")
    }

    // MARK: - Private

    private func startRecognitionTask() {
        // Tear down any in-flight request/task but *keep* the audio
        // engine running — starting and stopping the engine across
        // restarts creates long gaps in listening and occasionally
        // fails because CoreAudio hasn't released the input node yet.
        tearDownRecognitionTask(stoppingAudioEngine: false)
        // Reset the partial-log dedupe cache so the first transcript
        // after each restart always prints, making it obvious in the
        // console whether the listener is actually receiving audio.
        lastLoggedPartialTranscript = ""

        guard let speechRecognizer else { return }

        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            // Force on-device recognition so audio never leaves the Mac.
            // Without this the framework may fall back to Apple servers,
            // which defeats the privacy story of this feature.
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        self.activeRecognitionRequest = recognitionRequest

        // Install the audio tap on first run, and keep it installed
        // across recognition-task restarts so we don't miss buffers
        // in the handover window.
        let audioInputNode = audioEngine.inputNode
        let audioInputFormat = audioInputNode.outputFormat(forBus: 0)
        if !audioEngine.isRunning {
            audioInputNode.removeTap(onBus: 0)
            audioInputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: audioInputFormat
            ) { [weak self] audioBuffer, _ in
                // Hot-path: feed every buffer into the active
                // recognition request and drop the reference. Apple
                // Speech consumes and discards the audio internally.
                self?.activeRecognitionRequest?.append(audioBuffer)
            }

            audioEngine.prepare()
            do {
                try audioEngine.start()
            } catch {
                print("⚠️ Koko wake word: audio engine failed to start: \(error)")
                tearDownRecognitionTask(stoppingAudioEngine: true)
                return
            }
        }

        activeRecognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] recognitionResult, recognitionError in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let recognitionError {
                    // Most of these are benign ("no speech detected",
                    // "recognizer cancelled"). Log at debug volume and
                    // let the restart timer roll the task.
                    let nserror = recognitionError as NSError
                    if nserror.domain != "kAFAssistantErrorDomain" {
                        print("⚠️ Koko wake word: recognition error: \(recognitionError.localizedDescription)")
                    }
                    return
                }

                guard let recognitionResult else { return }

                let rawPartialTranscriptText = recognitionResult.bestTranscription.formattedString
                let normalizedPartialTranscriptText = Self.normalizeTranscriptForMatching(rawPartialTranscriptText)

                // Only log partials that contain a koko-like token —
                // ambient speech transcripts are noise in the console
                // and the variant list is well-tuned at this point.
                if !normalizedPartialTranscriptText.isEmpty,
                   normalizedPartialTranscriptText != self.lastLoggedPartialTranscript {
                    let partialContainsKokoLikeToken = normalizedPartialTranscriptText
                        .split(separator: " ")
                        .contains { token in
                            Self.standaloneKokoLikeTokens.contains(String(token))
                        }
                    if partialContainsKokoLikeToken {
                        print("🪺 Koko wake word partial: \"\(normalizedPartialTranscriptText)\"")
                    }
                    self.lastLoggedPartialTranscript = normalizedPartialTranscriptText
                }

                if self.normalizedTranscriptContainsWakePhrase(normalizedPartialTranscriptText) {
                    print("🪺 Koko wake word: detected in \"\(normalizedPartialTranscriptText)\"")
                    self.wakeWordDetectedPublisher.send(())
                    // The consumer (`CompanionManager.handleWakeWordDetection`)
                    // is responsible for calling `stop()` on us so the
                    // mic is free for the real dictation stream.
                }
            }
        }

        scheduleRecognitionTaskRestart()
    }

    private func scheduleRecognitionTaskRestart() {
        taskRestartTimer?.invalidate()
        taskRestartTimer = Timer.scheduledTimer(
            withTimeInterval: Self.recognitionTaskRestartIntervalSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.startRecognitionTask()
            }
        }
    }

    /// Lowercases, strips punctuation, and collapses whitespace so
    /// the matcher can stay simple. Apple Speech happily emits
    /// "Hey, Koko." / "Hey — koko!" / "hey  koko" all for the same
    /// utterance, and a raw substring match would miss most of them.
    private static func normalizeTranscriptForMatching(_ rawTranscriptText: String) -> String {
        let lowercased = rawTranscriptText.lowercased()
        let punctuationStripped = lowercased.unicodeScalars.filter { scalar in
            // Keep letters, digits, and whitespace — drop everything
            // else (commas, periods, apostrophes, quotes, em-dashes).
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
        }
        let rebuiltString = String(String.UnicodeScalarView(punctuationStripped))
        // Collapse any runs of whitespace into a single space.
        let collapsedWhitespace = rebuiltString
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsedWhitespace
    }

    private func normalizedTranscriptContainsWakePhrase(_ normalizedPartialTranscriptText: String) -> Bool {
        guard !normalizedPartialTranscriptText.isEmpty else { return false }

        // Match full-phrase variants first (most specific signal).
        for variantPhrase in Self.wakePhraseVariants {
            if normalizedPartialTranscriptText.contains(variantPhrase) {
                return true
            }
        }

        // Fall back to standalone "Koko-like" words as a wake signal.
        // These essentially never appear in normal English dictation,
        // so accepting them on their own gives a big reliability
        // improvement for users whose "hey" gets swallowed or
        // mistranscribed ("hay", "heyyy", "ok", etc.).
        let transcriptTokens = normalizedPartialTranscriptText
            .split(separator: " ")
            .map(String.init)
        for transcriptToken in transcriptTokens {
            if Self.standaloneKokoLikeTokens.contains(transcriptToken) {
                return true
            }
        }

        return false
    }

    private func tearDownRecognitionTask(stoppingAudioEngine: Bool) {
        taskRestartTimer?.invalidate()
        taskRestartTimer = nil

        activeRecognitionTask?.cancel()
        activeRecognitionTask = nil

        activeRecognitionRequest?.endAudio()
        activeRecognitionRequest = nil

        if stoppingAudioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }
}
