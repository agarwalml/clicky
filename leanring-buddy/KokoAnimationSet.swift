//
//  KokoAnimationSet.swift
//  leanring-buddy
//
//  Defines Koko's sprite animation sets. Each set maps to a behavioral
//  state (flying, perched, listening, etc.) and specifies per-frame
//  asset names and hold durations in the Pokemon Gen 5 "animation on
//  twos" style: key poses hold longer, transitions are quicker.
//
//  Timing values come from the sprite metadata in
//  `~/Documents/CC/koko_sprites/CLAUDE.md`.
//

import Foundation

/// A single sprite animation cycle. Each frame has its own hold
/// duration so the animation feels hand-crafted rather than
/// mechanically uniform.
struct KokoAnimationSet {
    /// Asset catalog names for each frame in the cycle.
    let frameNames: [String]

    /// How long each frame is held before advancing to the next,
    /// in seconds. Must be the same length as `frameNames`.
    let frameHoldDurations: [TimeInterval]

    /// Whether the animation loops back to frame 0 after the last
    /// frame, or stops on the final frame.
    let loops: Bool

    var frameCount: Int { frameNames.count }
}

// MARK: - Animation Library

extension KokoAnimationSet {
    /// Flap cycle — used when following cursor or flying. Key poses
    /// (wings up/down) hold longer, mid-positions are quick.
    static let flight = KokoAnimationSet(
        frameNames: ["koyal_flight_1", "koyal_flight_2", "koyal_flight_3", "koyal_flight_4"],
        frameHoldDurations: [0.280, 0.140, 0.280, 0.140],
        loops: true
    )

    /// Idle head-bob + blink — used when cursor hasn't moved for a
    /// couple of seconds. Holds the neutral and blink poses longer.
    static let perched = KokoAnimationSet(
        frameNames: ["koyal_perched_1", "koyal_perched_2", "koyal_perched_3", "koyal_perched_4"],
        frameHoldDurations: [0.350, 0.180, 0.350, 0.180],
        loops: true
    )

    /// Wing cupped to ear — used during push-to-talk / wake word
    /// recording. Holds the ear-cup pose (frame 3) longest.
    static let listening = KokoAnimationSet(
        frameNames: ["koyal_listening_1", "koyal_listening_2", "koyal_listening_3", "koyal_listening_4"],
        frameHoldDurations: [0.200, 0.200, 0.400, 0.200],
        loops: true
    )

    /// Wing-to-chin gesture — used while waiting for Claude's
    /// response. Holds the chin-pose (frame 3) longest.
    static let thinking = KokoAnimationSet(
        frameNames: ["koyal_thinking_1", "koyal_thinking_2", "koyal_thinking_3", "koyal_thinking_4"],
        frameHoldDurations: [0.180, 0.180, 0.400, 0.180],
        loops: true
    )

    /// Beak openness levels — amplitude-driven during TTS playback.
    /// Frame selection is driven by `currentAudioPowerLevel`, not by
    /// sequential cycling. The timing values here are used as a
    /// fallback minimum hold to prevent visual jitter.
    static let talking = KokoAnimationSet(
        frameNames: ["koyal_talking_1", "koyal_talking_2", "koyal_talking_3", "koyal_talking_4"],
        frameHoldDurations: [0.250, 0.180, 0.180, 0.250],
        loops: true
    )

    /// Wing outstretched — entrance animation when arriving at a
    /// pointed element. Frames 1→3 are a quick entrance, then 3↔4
    /// hold/loop while pointing.
    static let pointing = KokoAnimationSet(
        frameNames: ["koyal_pointing_1", "koyal_pointing_2", "koyal_pointing_3", "koyal_pointing_4"],
        frameHoldDurations: [0.160, 0.160, 0.400, 0.400],
        loops: true
    )

    /// Wings-tucked dive — one-shot during the bezier arc navigation
    /// flight toward a UI element. Holds tuck and flare poses longer.
    static let swoop = KokoAnimationSet(
        frameNames: ["koyal_swoop_1", "koyal_swoop_2", "koyal_swoop_3", "koyal_swoop_4"],
        frameHoldDurations: [0.140, 0.300, 0.140, 0.300],
        loops: true
    )
}
