//
//  CompanionTypedInputOverlay.swift
//  leanring-buddy
//
//  Spotlight-style typed input that appears right next to the koyal
//  companion sprite when the user hits the Option+Space global hotkey.
//  Lives in its own non-activating NSPanel (separate from the big cursor
//  overlay, which is click-through and therefore can't receive keystrokes)
//  so the TextField inside can actually take focus and accept typing.
//  Follows the cursor while visible so it stays visually docked to the
//  bird, and routes submissions through the exact same pipeline as
//  push-to-talk via `CompanionManager.submitTypedCommand(_:)`.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionTypedInputOverlayViewModel: ObservableObject {
    @Published var typedText: String = ""
    @Published var isVisible: Bool = false
}

// MARK: - Overlay Manager

@MainActor
final class CompanionTypedInputOverlayManager {
    private let overlayViewModel = CompanionTypedInputOverlayViewModel()
    private var overlayPanel: KeyableTypedInputPanel?
    private var cursorTrackingTimer: Timer?
    private var outsideClickMonitor: Any?

    /// Called when the user hits Return on a non-empty input. The manager
    /// hides the overlay before invoking, so downstream code can safely
    /// show overlays/alerts without fighting for focus.
    var onSubmit: ((String) -> Void)?

    private let kokoSpriteHalfSize: CGFloat = 26
    /// Gap between Koko's right edge and the panel's left edge.
    private let gapBetweenKokoAndPanel: CGFloat = 12

    /// Returns Koko's current screen-coordinate center. Set by
    /// `CompanionManager` to point at the published position that
    /// `BlueCursorView` updates every frame.
    var kokoScreenPositionProvider: (() -> CGPoint)?

    /// Fixed width of the input panel. Matches Spotlight's compact footprint.
    private let panelWidth: CGFloat = 380

    /// Approximate height of the single-line field with its padding.
    private let panelHeight: CGFloat = 56

    func toggle() {
        if overlayViewModel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        createPanelIfNeeded()
        overlayViewModel.typedText = ""
        repositionPanelNearCursor()
        // Bring the panel on screen and make it key *before* flipping the
        // view model's isVisible flag — the hosted SwiftUI view mounts in
        // response to that flag, and its TextField's focus assignment only
        // sticks if the parent window is already the key window.
        overlayPanel?.makeKeyAndOrderFront(nil)
        overlayPanel?.orderFrontRegardless()
        overlayViewModel.isVisible = true
        startCursorTracking()
        installOutsideClickMonitor()
    }

    func hide() {
        overlayViewModel.isVisible = false
        overlayViewModel.typedText = ""
        stopCursorTracking()
        removeOutsideClickMonitor()
        overlayPanel?.orderOut(nil)
    }

    // MARK: - Private

    private func createPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        let panel = KeyableTypedInputPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false

        let hostingView = NSHostingView(
            rootView: CompanionTypedInputOverlayView(
                overlayViewModel: overlayViewModel,
                onSubmit: { [weak self] submittedText in
                    self?.handleSubmit(submittedText)
                },
                onEscape: { [weak self] in
                    self?.hide()
                }
            )
            .frame(width: panelWidth)
        )
        hostingView.frame = initialFrame
        panel.contentView = hostingView

        overlayPanel = panel
    }

    private func handleSubmit(_ submittedText: String) {
        let trimmedSubmittedText = submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
        hide()
        guard !trimmedSubmittedText.isEmpty else { return }
        onSubmit?(trimmedSubmittedText)
    }

    /// 60fps cursor tracking so the panel stays glued to the bird while
    /// the user is typing — matching the dynamic feel the user asked for.
    private func startCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.repositionPanelNearCursor()
        }
    }

    private func stopCursorTracking() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
    }

    private func repositionPanelNearCursor() {
        guard let overlayPanel else { return }

        let kokoScreenCenter = kokoScreenPositionProvider?() ?? NSEvent.mouseLocation
        let panelSize = overlayPanel.frame.size

        var panelOriginX = kokoScreenCenter.x + kokoSpriteHalfSize + gapBetweenKokoAndPanel
        var panelOriginY = kokoScreenCenter.y - panelSize.height / 2

        if let currentScreen = screenContainingPoint(kokoScreenCenter) {
            let visibleFrame = currentScreen.visibleFrame

            if panelOriginX + panelSize.width > visibleFrame.maxX {
                panelOriginX = kokoScreenCenter.x - kokoSpriteHalfSize - gapBetweenKokoAndPanel - panelSize.width
            }
            if panelOriginY < visibleFrame.minY {
                panelOriginY = kokoScreenCenter.y
            }

            // Final clamp so the panel never leaves the visible frame.
            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - panelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - panelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    /// Dismisses the input when the user clicks anywhere outside it.
    /// Global monitors only fire for events *outside* our app, so clicks
    /// inside the input panel itself never reach this block.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

/// NSPanel subclass that can become key even with the `.nonactivatingPanel`
/// style. Required so the TextField inside actually receives keystrokes
/// without the whole app grabbing global focus the way a normal window would.
private final class KeyableTypedInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - SwiftUI View

private struct CompanionTypedInputOverlayView: View {
    @ObservedObject var overlayViewModel: CompanionTypedInputOverlayViewModel
    let onSubmit: (String) -> Void
    let onEscape: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        if overlayViewModel.isVisible {
            TextField("Ask Koko...", text: $overlayViewModel.typedText)
                .textFieldStyle(.plain)
                .font(.pixel(size: 20))
                .foregroundColor(DS.Colors.textPrimary)
                .tint(DS.Colors.overlayCursorRed)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(PixelDialogueBoxBackground(
                    fillColor: DS.Colors.surface1.opacity(0.92)
                ))
                .focused($isFieldFocused)
                .onSubmit {
                    onSubmit(overlayViewModel.typedText)
                }
                .onExitCommand {
                    onEscape()
                }
                .onAppear {
                    DispatchQueue.main.async {
                        isFieldFocused = true
                    }
                }
        }
    }
}
