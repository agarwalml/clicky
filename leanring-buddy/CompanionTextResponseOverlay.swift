//
//  CompanionTextResponseOverlay.swift
//  leanring-buddy
//
//  Larger, scrollable response panel used when Koko is in text-only
//  mode. The normal overlay's small speech bubble is fine for a
//  "hey!" one-liner but cramped when Koko is returning multi-sentence
//  answers you actually want to *read* — this panel gives that
//  content its own surface with proper word wrapping, scrolling when
//  content overflows, and a dismiss affordance.
//
//  Structure mirrors `CompanionTypedInputOverlay`: a non-activating
//  NSPanel that can *become* key (so text inside can be selected and
//  copied if we add that later), a 60fps cursor-tracking timer so the
//  panel stays docked near the bird, and an outside-click monitor
//  that hides the panel when the user clicks elsewhere.
//

import AppKit
import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class CompanionTextResponseOverlayViewModel: ObservableObject {
    @Published var streamingResponseText: String = ""
    @Published var isVisible: Bool = false
    /// When true, the panel shows a small spinner while waiting for
    /// Claude's first chunk. Cleared as soon as any text arrives.
    @Published var isAwaitingFirstChunk: Bool = false
}

// MARK: - Overlay Manager

@MainActor
final class CompanionTextResponseOverlayManager {
    private let overlayViewModel = CompanionTextResponseOverlayViewModel()
    private var overlayPanel: KeyableTextResponsePanel?
    private var cursorTrackingTimer: Timer?
    private var outsideClickMonitor: Any?
    private var escapeKeyMonitor: Any?

    private let kokoSpriteHalfSize: CGFloat = 26
    /// Gap between Koko's right edge and the panel's left edge.
    private let gapBetweenKokoAndPanel: CGFloat = 12

    /// Returns Koko's current screen-coordinate center. Set by
    /// `CompanionManager` to point at the published position that
    /// `BlueCursorView` updates every frame. Falls back to the mouse
    /// cursor offset if not configured.
    var kokoScreenPositionProvider: (() -> CGPoint)?

    private let panelWidth: CGFloat = 500
    private let panelMaximumHeight: CGFloat = 600

    /// Show the panel in a "waiting for first chunk" state. Called
    /// when a text-mode response has just been kicked off so the
    /// user sees an immediate acknowledgement that Koko is working
    /// on it, even before the first streaming chunk arrives.
    func beginStreamingResponse() {
        createPanelIfNeeded()
        overlayViewModel.streamingResponseText = ""
        overlayViewModel.isAwaitingFirstChunk = true
        overlayViewModel.isVisible = true
        resizePanelToFitContent()
        repositionPanelNearCursor()
        // Don't use makeKeyAndOrderFront — that steals keyboard
        // focus from whatever window the user is typing in, forcing
        // them to re-click their editor/browser/terminal. The
        // response panel is read-only so it doesn't need key status.
        overlayPanel?.orderFrontRegardless()
        startCursorTracking()
        installOutsideClickMonitor()
        installEscapeKeyMonitor()
        print("📝 Text response panel: opened")
    }

    /// Update the streaming response text. Called on every chunk
    /// arrival from the Claude streaming API.
    func updateStreamingResponse(text: String) {
        overlayViewModel.streamingResponseText = text
        if !text.isEmpty {
            overlayViewModel.isAwaitingFirstChunk = false
        }
        resizePanelToFitContent()
    }

    /// Marks the response as complete. The panel stays visible (the
    /// user may still be reading) — hiding happens via outside click,
    /// Escape, or the next command.
    func finishStreamingResponse() {
        overlayViewModel.isAwaitingFirstChunk = false
    }

    func hide() {
        overlayViewModel.isVisible = false
        overlayViewModel.isAwaitingFirstChunk = false
        overlayViewModel.streamingResponseText = ""
        stopCursorTracking()
        removeOutsideClickMonitor()
        removeEscapeKeyMonitor()
        overlayPanel?.orderOut(nil)
    }

    var isVisible: Bool {
        overlayViewModel.isVisible
    }

    // MARK: - Private

    private func createPanelIfNeeded() {
        if overlayPanel != nil { return }

        let initialFrame = NSRect(x: 0, y: 0, width: panelWidth, height: 120)
        let panel = KeyableTextResponsePanel(
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
        // Allow clicks to pass through to windows behind the panel
        // so the user can interact with UI elements that happen to
        // be underneath Koko's text bubble.
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(
            rootView: CompanionTextResponseOverlayView(
                overlayViewModel: overlayViewModel,
                panelMaximumHeight: panelMaximumHeight,
                onDismiss: { [weak self] in
                    self?.hide()
                }
            )
            .frame(width: panelWidth)
        )
        hostingView.frame = initialFrame
        panel.contentView = hostingView

        overlayPanel = panel
    }

    /// Resizes the NSPanel to match its SwiftUI content. Called on
    /// every streaming text update so the panel grows as text arrives
    /// instead of clipping at the initial 120pt height.
    private func resizePanelToFitContent() {
        guard let overlayPanel, let contentView = overlayPanel.contentView else { return }
        let fittingSize = contentView.fittingSize
        let newWidth = min(fittingSize.width, panelWidth)
        let newHeight = min(fittingSize.height, panelMaximumHeight)
        var frame = overlayPanel.frame
        let heightDelta = newHeight - frame.height
        frame.size = CGSize(width: newWidth, height: newHeight)
        // Grow upward (toward Koko) so the panel doesn't push down
        // off the bottom of the screen as text streams in.
        frame.origin.y -= heightDelta
        overlayPanel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: frame.size)
    }

    /// 60fps cursor tracking so the panel stays glued to the bird
    /// while the user moves their cursor.
    private func startCursorTracking() {
        cursorTrackingTimer?.invalidate()
        // Run directly on the main RunLoop (not via Task) so
        // position updates aren't delayed by the Task queue.
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

        // Use Koko's actual screen position (published by BlueCursorView
        // every frame) so the panel follows the bird during navigation
        // flights, not just during normal cursor-following.
        let kokoScreenCenter = kokoScreenPositionProvider?() ?? NSEvent.mouseLocation
        let currentPanelSize = overlayPanel.frame.size

        var panelOriginX = kokoScreenCenter.x + kokoSpriteHalfSize + gapBetweenKokoAndPanel
        var panelOriginY = kokoScreenCenter.y - currentPanelSize.height / 2

        if let currentScreen = screenContainingPoint(kokoScreenCenter) {
            let visibleFrame = currentScreen.visibleFrame

            if panelOriginX + currentPanelSize.width > visibleFrame.maxX {
                panelOriginX = kokoScreenCenter.x - kokoSpriteHalfSize - gapBetweenKokoAndPanel - currentPanelSize.width
            }
            if panelOriginY < visibleFrame.minY {
                panelOriginY = kokoScreenCenter.y
            }

            panelOriginX = max(visibleFrame.minX, min(panelOriginX, visibleFrame.maxX - currentPanelSize.width))
            panelOriginY = max(visibleFrame.minY, min(panelOriginY, visibleFrame.maxY - currentPanelSize.height))
        }

        overlayPanel.setFrameOrigin(CGPoint(x: panelOriginX, y: panelOriginY))
    }

    /// Dismisses the panel when the user clicks anywhere outside of
    /// it. Global monitors only fire for events *outside* our app,
    /// so clicks inside the panel itself never reach this block.
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

    /// Listens for the Escape key globally so the user can dismiss
    /// the response panel from any app. The panel isn't key (to
    /// avoid stealing focus), so `.onExitCommand` in SwiftUI never
    /// fires — this local monitor catches it instead.
    private func installEscapeKeyMonitor() {
        removeEscapeKeyMonitor()
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor [weak self] in
                    self?.hide()
                }
                return nil // consume the event
            }
            return event
        }
    }

    private func removeEscapeKeyMonitor() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
            self.escapeKeyMonitor = nil
        }
    }

    private func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

/// NSPanel subclass that can become key even with `.nonactivatingPanel`
/// style so any interactive elements (scroll view focus, future
/// "copy" button, etc.) can receive events.
private final class KeyableTextResponsePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - SwiftUI View

private struct CompanionTextResponseOverlayView: View {
    @ObservedObject var overlayViewModel: CompanionTextResponseOverlayViewModel
    let panelMaximumHeight: CGFloat
    let onDismiss: () -> Void

    @State private var loadingDotCount: Int = 0

    var body: some View {
        if overlayViewModel.isVisible {
            VStack(alignment: .leading, spacing: 0) {
                // Header bar — "Koko" label + dismiss hint
                HStack(spacing: 6) {
                    Text("Koko")
                        .font(.pixel(size: 16))
                        .foregroundColor(DS.Colors.textTertiary)

                    Spacer()

                    Text("esc")
                        .font(.pixel(size: 12))
                        .foregroundColor(DS.Colors.textTertiary.opacity(0.6))
                }
                .padding(.bottom, 8)

                // Thin pixel divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(height: 1)
                    .padding(.bottom, 10)

                if overlayViewModel.isAwaitingFirstChunk && overlayViewModel.streamingResponseText.isEmpty {
                    Text(String(repeating: ".", count: loadingDotCount + 1))
                        .font(.pixel(size: 22))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onAppear {
                            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                                loadingDotCount = (loadingDotCount + 1) % 3
                            }
                        }
                } else {
                    Text(overlayViewModel.streamingResponseText)
                        .font(.pixel(size: 22))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(8)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(PixelDialogueBoxBackground(
                fillColor: DS.Colors.surface1.opacity(0.92)
            ))
            .onExitCommand {
                onDismiss()
            }
        }
    }
}
