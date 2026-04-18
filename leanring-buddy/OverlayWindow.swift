//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(
            x: localX + BlueCursorView.buddyCursorOffsetX,
            y: localY + BlueCursorView.buddyCursorOffsetY
        ))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Koyal Sprite Animation State

    /// Rendered sprite frame size (points). Sized so the pixel-art frames
    /// have real presence on screen — small enough to not be obnoxious,
    /// large enough to read as a character rather than a cursor accent.
    private let koyalSpriteRenderedSize: CGFloat = 96

    static let buddyCursorOffsetX: CGFloat = 55
    static let buddyCursorOffsetY: CGFloat = 38

    // MARK: - Sprite Animation State

    /// The animation set currently driving the sprite. Changes when
    /// the bird's behavioral state changes (idle → listening, etc.).
    @State private var currentAnimationSet: KokoAnimationSet = .flight

    /// Current frame index within `currentAnimationSet`.
    @State private var currentSpriteFrameIndex: Int = 0

    /// The asset name rendered by the Image view. Derived from
    /// `currentAnimationSet.frameNames[currentSpriteFrameIndex]`.
    @State private var currentSpriteFrameName: String = KokoAnimationSet.flight.frameNames[0]

    /// Timer that advances the sprite frame. Uses variable per-frame
    /// delays (Pokemon "animation on twos" style) instead of a fixed
    /// interval, so key poses hold longer and transitions are quick.
    @State private var spriteFrameTimer: Timer?

    /// How many seconds the cursor has been stationary. When this
    /// exceeds `cursorIdleThresholdSeconds`, the animation switches
    /// from flight to perched.
    @State private var cursorIdleSeconds: TimeInterval = 0
    private let cursorIdleThresholdSeconds: TimeInterval = 1.5

    /// Last cursor position used to detect whether the cursor has
    /// moved (for idle detection). Different from
    /// `previousCursorXForFacingCheck` which only tracks X for
    /// horizontal flip — this tracks both axes with a larger
    /// movement threshold.
    @State private var lastCursorPositionForIdleCheck: CGPoint = .zero

    /// Whether the koyal sprite should be mirrored horizontally so it appears
    /// to face left. The source sprite faces right, so `false` = facing right.
    /// Flipped based on direction of travel — either cursor movement while
    /// following, or the vector to the target when navigating.
    @State private var isKoyalSpriteFacingLeft: Bool = false

    /// Last cursor X position observed during following, used to compute
    /// horizontal direction without flipping on every sub-pixel jitter.
    @State private var previousCursorXForFacingCheck: CGFloat = 0

    /// True while the bird is performing its first-launch entrance flight
    /// from the edge of the screen toward the cursor. Cursor tracking is
    /// suspended during this window so the intro animation plays cleanly.
    @State private var isPerformingIntroFlight: Bool = false

    /// True while the bird is swooping back from the nest corner to
    /// the cursor via a one-shot bezier arc. Prevents the nest-return
    /// detection block from re-triggering on every tick.
    @State private var isNestReturnFlightInProgress: Bool = false

    /// Timer driving the frame-by-frame position interpolation of the
    /// intro flight. Using a timer (rather than `withAnimation`) avoids
    /// SwiftUI coalescing the edge→rest state changes into a single
    /// render pass, which was causing the bird to skip the flight and
    /// just appear at the cursor.
    @State private var introFlightTimer: Timer?

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm koko"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.pixel(size: 18))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(PixelDialogueBoxBackground(
                        fillColor: DS.Colors.overlayCursorRed.opacity(0.9),
                        borderColor: .white.opacity(0.6),
                        outerBorderColor: DS.Colors.overlayCursorRed.opacity(0.3),
                        pixelSize: 2
                    ))
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + koyalSpriteRenderedSize / 2 + 6 + (bubbleSize.width / 2), y: cursorPosition.y)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.pixel(size: 18))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(PixelDialogueBoxBackground(
                        fillColor: DS.Colors.overlayCursorRed.opacity(0.9),
                        borderColor: .white.opacity(0.6),
                        outerBorderColor: DS.Colors.overlayCursorRed.opacity(0.3),
                        pixelSize: 2
                    ))
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + koyalSpriteRenderedSize / 2 + 6 + (bubbleSize.width / 2), y: cursorPosition.y)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            // Text-mode toggle feedback pill — fades in for ~1.6s when
            // the user hits Ctrl+Shift+T so the hotkey has visible
            // confirmation. Sits just below the koyal sprite in the
            // same slot the waveform uses during listening.
            if companionManager.isShowingTextModeToggleFeedback
                && !companionManager.textModeToggleFeedbackText.isEmpty {
                Text(companionManager.textModeToggleFeedbackText)
                    .font(.pixel(size: 16))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(PixelDialogueBoxBackground(
                        fillColor: DS.Colors.overlayCursorRed.opacity(0.9),
                        borderColor: .white.opacity(0.6),
                        outerBorderColor: DS.Colors.overlayCursorRed.opacity(0.3),
                        pixelSize: 2
                    ))
                    .fixedSize()
                    .position(
                        x: cursorPosition.x + koyalSpriteRenderedSize / 2 + 6,
                        y: cursorPosition.y
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .animation(.easeOut(duration: 0.2), value: companionManager.isShowingTextModeToggleFeedback)
            }

            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.pixel(size: 18))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(PixelDialogueBoxBackground(
                        fillColor: DS.Colors.overlayCursorRed.opacity(0.9),
                        borderColor: .white.opacity(0.6),
                        outerBorderColor: DS.Colors.overlayCursorRed.opacity(0.3),
                        pixelSize: 2
                    ))
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    // Park the bubble just past the right edge of the koyal
                    // sprite (40pt wide, centered on cursor) with a small
                    // gap so it sits *next to* the bird instead of overlapping
                    // its right half.
                    .position(
                        x: cursorPosition.x + (koyalSpriteRenderedSize / 2) + 8 + (navigationBubbleSize.width / 2),
                        y: cursorPosition.y
                    )
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Koyal bird sprite cursor — shown when idle or while TTS is playing (responding).
            // All three states (sprite, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            //
            // The sprite is horizontally mirrored (not rotated) based on direction
            // of travel, because rotating a bird sprite to match a bezier tangent
            // would make it fly upside-down through the apex of the arc.
            Image(currentSpriteFrameName)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: koyalSpriteRenderedSize, height: koyalSpriteRenderedSize)
                // New sprites face LEFT natively (old ones faced right),
                // so the mirror logic is inverted: facing-left = show
                // source as-is, facing-right = flip horizontally.
                .scaleEffect(x: isKoyalSpriteFacingLeft ? 1 : -1, y: 1)
                .scaleEffect(buddyFlightScale)
                .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 2)
                .opacity(buddyIsVisibleOnThisScreen && (companionManager.voiceState == .idle || companionManager.voiceState == .responding || companionManager.voiceState == .listening || companionManager.voiceState == .processing) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    isPerformingIntroFlight
                        // During the intro flight, let the explicit
                        // withAnimation(.easeOut) in .onAppear own the
                        // cursorPosition interpolation instead of fighting
                        // the usual follow-cursor spring.
                        ? nil
                        : (buddyNavigationMode == .followingCursor
                            ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                            : nil),
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(.easeInOut(duration: 0.15), value: isKoyalSpriteFacingLeft)

            // Blue waveform — sits *below* the koyal sprite while listening so
            // the bird stays visible on top and the waveform clearly belongs
            // to "what clicky is hearing right now" without covering the
            // character itself.
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(
                    x: cursorPosition.x,
                    y: cursorPosition.y + koyalSpriteRenderedSize / 2 + 10
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Red spinner — sits at the bottom-right corner of the koyal
            // sprite during processing so the bird stays visible and the
            // loading indicator reads as a small badge on the character
            // rather than replacing it.
            BlueCursorSpinnerView()
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(
                    x: cursorPosition.x + koyalSpriteRenderedSize / 2 - 2,
                    y: cursorPosition.y + koyalSpriteRenderedSize / 2 - 2
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyRestingPosition = CGPoint(
                x: swiftUIPosition.x + Self.buddyCursorOffsetX,
                y: swiftUIPosition.y + Self.buddyCursorOffsetY
            )

            startSpriteAnimation()

            // First-launch entrance: Koko spawns at whichever horizontal
            // edge of this screen is furthest from the cursor, then flies
            // in to its normal resting offset. Only runs on the very first
            // appearance and only if the cursor is on this screen so the
            // flight is actually visible to the user.
            if isFirstAppearance && isCursorOnThisScreen {
                // Always spawn Koko just past the *right* edge of the
                // screen so the entrance reads the same way every time.
                // `+ koyalSpriteRenderedSize` pushes the sprite bounding
                // box fully offscreen so the flight starts from beyond
                // the visible area.
                let introFlightStartX: CGFloat = screenFrame.width + koyalSpriteRenderedSize
                let introFlightStartPosition = CGPoint(
                    x: introFlightStartX,
                    y: buddyRestingPosition.y
                )

                // Suspend cursor tracking, snap the sprite to the edge,
                // and make it visible immediately. The edge is offscreen
                // so the instant visibility isn't visible, while fading
                // in simultaneously with flying was washing the entrance
                // out.
                self.isPerformingIntroFlight = true
                self.cursorPosition = introFlightStartPosition
                self.previousCursorXForFacingCheck = introFlightStartX
                // Face the direction of travel (leftward, since we're
                // flying in from the right edge). Sprite source faces
                // right; `true` mirrors it to face left.
                self.isKoyalSpriteFacingLeft = true
                self.cursorOpacity = 1.0

                startIntroFlight(
                    from: introFlightStartPosition,
                    to: buddyRestingPosition
                )
            } else {
                // Subsequent appearances (user toggled cursor off then on,
                // re-added a screen, etc.) — no intro flight, just pop in
                // at the resting position and start tracking.
                self.cursorPosition = buddyRestingPosition
                self.previousCursorXForFacingCheck = buddyRestingPosition.x
                self.cursorOpacity = 1.0
                startTrackingCursor()
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            introFlightTimer?.invalidate()
            introFlightTimer = nil
            spriteFrameTimer?.invalidate()
            spriteFrameTimer = nil
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // While the intro flight from the screen edge is playing, leave
            // cursorPosition alone — the withAnimation in .onAppear owns it
            // for the duration of the flight.
            if self.isPerformingIntroFlight {
                return
            }

            // Always update the animation set even when cursor position
            // tracking is suspended (navigation flight, pointing, etc.)
            self.updateAnimationSetForCurrentState()

            // ── PRIORITY 1: Navigation/pointing always wins ──
            // Active pointing/navigation takes absolute priority over
            // nesting. Without this guard, the nest block below would
            // override a pointing animation and pull the bird to the
            // corner mid-flight.
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // ── PRIORITY 2: Nesting ──
            // Only runs when the bird is in .followingCursor mode (no
            // active pointing/navigation). Eases toward the nest corner.
            if self.companionManager.isNesting,
               let nestScreenPos = self.companionManager.nestTargetScreenPosition {
                let nestSwiftUI = self.convertScreenPointToSwiftUICoordinates(nestScreenPos)
                let targetPosition = CGPoint(x: nestSwiftUI.x, y: nestSwiftUI.y)
                let dx = targetPosition.x - self.cursorPosition.x
                let dy = targetPosition.y - self.cursorPosition.y
                let distance = hypot(dx, dy)
                if distance > 2 {
                    let easeFactor: CGFloat = 0.04
                    self.cursorPosition = CGPoint(
                        x: self.cursorPosition.x + dx * easeFactor,
                        y: self.cursorPosition.y + dy * easeFactor
                    )
                    if dx < -4 { self.isKoyalSpriteFacingLeft = true }
                    else if dx > 4 { self.isKoyalSpriteFacingLeft = false }
                    self.switchToAnimationSet(.flight)
                } else {
                    self.cursorPosition = targetPosition
                    let isOnRightSideOfScreen = targetPosition.x > self.screenFrame.width / 2
                    self.isKoyalSpriteFacingLeft = isOnRightSideOfScreen
                    self.switchToAnimationSet(.perched)
                }
                self.publishKokoScreenPosition()
                return
            }

            // ── PRIORITY 3: Bezier swoop back from nest ──
            // When nest state just flipped off and bird is far from
            // cursor, trigger a one-shot bezier arc flight back. Uses
            // the same arc system as element pointing for a smooth swoop.
            if !self.companionManager.isNesting
                && self.companionManager.nestTargetScreenPosition == nil
                && !self.isNestReturnFlightInProgress {
                let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let targetX = swiftUIPosition.x + Self.buddyCursorOffsetX
                let targetY = swiftUIPosition.y + Self.buddyCursorOffsetY
                let distanceToCursor = hypot(targetX - self.cursorPosition.x, targetY - self.cursorPosition.y)
                if distanceToCursor > 80 {
                    self.isNestReturnFlightInProgress = true
                    let cursorTarget = CGPoint(x: targetX, y: targetY)
                    self.cursorPositionWhenNavigationStarted = swiftUIPosition
                    self.buddyNavigationMode = .navigatingToTarget
                    self.isReturningToCursor = true
                    self.switchToAnimationSet(.swoop)
                    self.animateBezierFlightArc(to: cursorTarget) {
                        self.finishNavigationAndResumeFollowing()
                        self.isNestReturnFlightInProgress = false
                    }
                    return
                }
            }

            // ── PRIORITY 4: Normal cursor following ──
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + Self.buddyCursorOffsetX
            let buddyY = swiftUIPosition.y + Self.buddyCursorOffsetY
            let newCursorPosition = CGPoint(x: buddyX, y: buddyY)

            // Flip the sprite horizontally to face the direction of cursor movement.
            // Only flip when the horizontal delta exceeds a small threshold so the
            // bird doesn't jitter back and forth on sub-pixel movement.
            let horizontalDelta = newCursorPosition.x - self.previousCursorXForFacingCheck
            let horizontalFlipThreshold: CGFloat = 4
            if horizontalDelta < -horizontalFlipThreshold {
                if !self.isKoyalSpriteFacingLeft {
                    self.isKoyalSpriteFacingLeft = true
                }
                self.previousCursorXForFacingCheck = newCursorPosition.x
            } else if horizontalDelta > horizontalFlipThreshold {
                if self.isKoyalSpriteFacingLeft {
                    self.isKoyalSpriteFacingLeft = false
                }
                self.previousCursorXForFacingCheck = newCursorPosition.x
            }

            self.cursorPosition = newCursorPosition
            self.publishKokoScreenPosition()
            self.updateCursorIdleTracking(newPosition: newCursorPosition)
            self.updateAnimationSetForCurrentState()
        }
    }

    /// Converts the bird's current SwiftUI position back to macOS screen
    /// coordinates and pushes it to `CompanionManager.kokoCurrentScreenPosition`
    /// so external panels (typed input, text response) can track where
    /// Koko *actually* is — not just where the mouse cursor is.
    private func publishKokoScreenPosition() {
        let screenX = cursorPosition.x + screenFrame.origin.x
        let screenY = (screenFrame.origin.y + screenFrame.height) - cursorPosition.y
        companionManager.kokoCurrentScreenPosition = CGPoint(x: screenX, y: screenY)
    }

    // MARK: - Intro Flight

    /// Frame-by-frame interpolation of the first-launch entrance flight.
    /// Runs on a 60fps `Timer` (mirroring the navigation arc flight) so
    /// SwiftUI can't coalesce the edge→rest state transitions into a
    /// single render pass — the earlier `withAnimation` version was
    /// silently skipping straight to the cursor position.
    private func startIntroFlight(
        from introFlightStartPosition: CGPoint,
        to introFlightEndPosition: CGPoint
    ) {
        introFlightTimer?.invalidate()

        let introFlightDurationSeconds: Double = 1.6
        let frameInterval: TimeInterval = 1.0 / 60.0
        let totalFrames = Int(introFlightDurationSeconds / frameInterval)
        var currentFrame = 0

        introFlightTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame >= totalFrames {
                self.introFlightTimer?.invalidate()
                self.introFlightTimer = nil
                self.cursorPosition = introFlightEndPosition
                self.previousCursorXForFacingCheck = introFlightEndPosition.x
                self.isPerformingIntroFlight = false
                // Hand off to normal cursor tracking once the flight
                // completes, and start the "hey! i'm koko" welcome
                // bubble a beat later so it doesn't collide visually
                // with the arrival.
                self.startTrackingCursor()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.bubbleOpacity = 0.0
                    self.startWelcomeAnimation()
                }
                return
            }

            // Smoothstep easeOut-ish progression: 1 - (1 - t)^3 gives a
            // strong initial velocity that decays toward the cursor,
            // which reads as a "landing" approach.
            let linearProgress = Double(currentFrame) / Double(totalFrames)
            let oneMinusProgress = 1.0 - linearProgress
            let easedProgress = 1.0 - (oneMinusProgress * oneMinusProgress * oneMinusProgress)

            let interpolatedX = introFlightStartPosition.x
                + (introFlightEndPosition.x - introFlightStartPosition.x) * CGFloat(easedProgress)
            let interpolatedY = introFlightStartPosition.y
                + (introFlightEndPosition.y - introFlightStartPosition.y) * CGFloat(easedProgress)

            self.cursorPosition = CGPoint(x: interpolatedX, y: interpolatedY)
            self.publishKokoScreenPosition()
        }
    }

    // MARK: - Sprite Animation System

    /// Switches to a new animation set and starts cycling through its
    /// frames with per-frame eased timing. If the requested set is
    /// already active, this is a no-op (prevents restart flicker).
    private func switchToAnimationSet(_ newAnimationSet: KokoAnimationSet) {
        // Compare by first frame name as a cheap identity check — each
        // animation set has unique asset names.
        guard newAnimationSet.frameNames.first != currentAnimationSet.frameNames.first else { return }
        currentAnimationSet = newAnimationSet
        currentSpriteFrameIndex = 0
        currentSpriteFrameName = newAnimationSet.frameNames[0]
        scheduleNextSpriteFrame()
    }

    /// Starts the variable-delay frame cycling. Called once on appear
    /// and again whenever the animation set changes.
    private func startSpriteAnimation() {
        scheduleNextSpriteFrame()
    }

    /// Schedules the next frame advance using the *current* frame's
    /// hold duration. This is the Pokemon "animation on twos" pattern:
    /// `setTimeout` with variable delays rather than `setInterval`
    /// with a fixed framerate.
    private func scheduleNextSpriteFrame() {
        spriteFrameTimer?.invalidate()

        let holdDuration = currentAnimationSet.frameHoldDurations[currentSpriteFrameIndex]

        spriteFrameTimer = Timer.scheduledTimer(
            withTimeInterval: holdDuration,
            repeats: false
        ) { _ in
            let nextFrameIndex: Int
            if self.currentAnimationSet.loops {
                nextFrameIndex = (self.currentSpriteFrameIndex + 1) % self.currentAnimationSet.frameCount
            } else {
                nextFrameIndex = min(self.currentSpriteFrameIndex + 1, self.currentAnimationSet.frameCount - 1)
            }
            self.currentSpriteFrameIndex = nextFrameIndex
            self.currentSpriteFrameName = self.currentAnimationSet.frameNames[nextFrameIndex]
            self.scheduleNextSpriteFrame()
        }
    }

    /// Evaluates the current behavioral state and switches to the
    /// appropriate animation set. Called from the cursor-tracking
    /// timer on every tick so transitions are immediate.
    private func updateAnimationSetForCurrentState() {
        let voiceState = companionManager.voiceState

        // Navigation modes take priority over voice state.
        if buddyNavigationMode == .navigatingToTarget {
            switchToAnimationSet(.swoop)
            return
        }
        if buddyNavigationMode == .pointingAtTarget {
            switchToAnimationSet(.pointing)
            return
        }

        switch voiceState {
        case .listening:
            switchToAnimationSet(.listening)
        case .processing:
            switchToAnimationSet(.thinking)
        case .responding:
            updateTalkingAnimation()
        case .idle:
            // If cursor has been still long enough, perch. Otherwise fly.
            if cursorIdleSeconds >= cursorIdleThresholdSeconds {
                switchToAnimationSet(.perched)
            } else {
                switchToAnimationSet(.flight)
            }
        }
    }

    /// Talking animation — just loops through the frames like every
    /// other animation set. No fancy amplitude-driven logic.
    private func updateTalkingAnimation() {
        switchToAnimationSet(.talking)
    }

    /// Tracks cursor movement and updates `cursorIdleSeconds` so the
    /// perched animation kicks in after the cursor is still.
    private func updateCursorIdleTracking(newPosition: CGPoint) {
        let movementThreshold: CGFloat = 6
        let distance = hypot(
            newPosition.x - lastCursorPositionForIdleCheck.x,
            newPosition.y - lastCursorPositionForIdleCheck.y
        )
        if distance > movementThreshold {
            cursorIdleSeconds = 0
            lastCursorPositionForIdleCheck = newPosition
        } else {
            // Timer fires at ~60fps = 0.016s per tick
            cursorIdleSeconds += 0.016
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flip the sprite to face the target for the whole flight. Cursor
        // tracking is paused during navigation, so we can't rely on the
        // following-mode flip logic.
        let flightGoesLeft = deltaX < 0
        if flightGoesLeft != isKoyalSpriteFacingLeft {
            isKoyalSpriteFacingLeft = flightGoesLeft
        }

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)
            self.publishKokoScreenPosition()

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        // If the bird was nesting before this pointing flight, fly
        // back to the nest corner instead of the cursor.
        if let savedNest = companionManager.savedNestPosition {
            let nestInSwiftUI = convertScreenPointToSwiftUICoordinates(savedNest)
            cursorPositionWhenNavigationStarted = nestInSwiftUI
            buddyNavigationMode = .navigatingToTarget
            isReturningToCursor = true
            animateBezierFlightArc(to: nestInSwiftUI) {
                self.finishNavigationAndResumeFollowing()
                // Bird has landed back at nest — clear savedNestPosition
                // so future observations without nesting don't
                // accidentally fly back here. isNesting and
                // nestTargetScreenPosition stay set so the cursor
                // tracking timer's nest block keeps the bird perched.
                self.companionManager.savedNestPosition = nil
            }
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(
            x: cursorInSwiftUI.x + Self.buddyCursorOffsetX,
            y: cursorInSwiftUI.y + Self.buddyCursorOffsetY
        )

        cursorPositionWhenNavigationStarted = cursorInSwiftUI
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        // Seed the facing-check baseline so the following-mode flip logic
        // doesn't misfire on the first post-flight cursor update.
        previousCursorXForFacingCheck = cursorPosition.x
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Onboarding video is intentionally skipped — Koko's
                    // intro flight + welcome bubble are the entire
                    // first-launch experience now.
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorRed)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorRed.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Cursor Spinner

/// A small red spinning indicator that sits at the bottom-right corner of
/// the koyal sprite while the AI is processing a voice input. Scaled down
/// from the previous cursor-replacement version so it reads as a badge
/// rather than taking over the whole companion.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorRed.opacity(0.0),
                        DS.Colors.overlayCursorRed
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
            )
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorRed.opacity(0.6), radius: 5, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
