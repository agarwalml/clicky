//
//  KokoSoundEffects.swift
//  leanring-buddy
//
//  8-bit chiptune sound effects for Koko's state transitions. Each
//  chirp/ding/hum is a short square-wave-style audio clip generated
//  from simple sine synth expressions, giving the companion the same
//  feel as a Pokemon overworld companion's SFX.
//
//  The manager pre-loads all clips on init so playback is instant
//  with no disk I/O on the hot path.
//

import AVFoundation
import Foundation

@MainActor
final class KokoSoundEffects {
    /// Master volume for all chirps. Intentionally low so they sit
    /// *under* the user's music/conversation rather than on top.
    var masterVolume: Float = 0.35

    /// Whether chirps are enabled at all. Toggled by the user in the
    /// menu bar panel or via a future hotkey.
    var isEnabled: Bool = true

    private var preloadedPlayers: [SoundEffect: AVAudioPlayer] = [:]

    enum SoundEffect: String, CaseIterable {
        /// Short ascending chirp — wake word detected.
        case wake = "chirp_wake"
        /// Soft chirp — push-to-talk listen started.
        case listen = "chirp_listen"
        /// Low sustained hum — processing / waiting for Claude.
        case think = "hum_think"
        /// Rapid trill — response finished successfully.
        case done = "trill_done"
        /// Bright single note — element pointed at.
        case point = "ding_point"
        /// Descending tone — error occurred.
        case error = "tone_error"
        /// Short click — text mode toggled.
        case toggle = "click_toggle"
        /// Kookoo voice intro — app startup.
        case kookoo = "kookoo_intro"
    }

    init() {
        preloadAllSounds()
    }

    /// Plays the given sound effect at `masterVolume`. No-op if
    /// `isEnabled` is false or the clip failed to preload.
    func play(_ soundEffect: SoundEffect) {
        guard isEnabled else { return }

        // For the kookoo intro, use the mp3 extension. Everything
        // else is wav.
        let fileExtension = soundEffect == .kookoo ? "mp3" : "wav"

        // Re-create the player each time so overlapping plays work
        // (AVAudioPlayer can only play one instance at a time).
        guard let url = Bundle.main.url(
            forResource: soundEffect.rawValue,
            withExtension: fileExtension
        ) else {
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = masterVolume
            player.play()
            // Hold a strong reference so the player doesn't dealloc
            // before playback finishes.
            preloadedPlayers[soundEffect] = player
        } catch {
            print("⚠️ Koko SFX: failed to play \(soundEffect.rawValue): \(error)")
        }
    }

    private func preloadAllSounds() {
        for soundEffect in SoundEffect.allCases {
            let fileExtension = soundEffect == .kookoo ? "mp3" : "wav"
            guard let url = Bundle.main.url(
                forResource: soundEffect.rawValue,
                withExtension: fileExtension
            ) else {
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                preloadedPlayers[soundEffect] = player
            } catch {
                // Not fatal — the sound just won't play.
            }
        }
    }
}
