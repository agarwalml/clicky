//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Clicky toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 14)

                sessionToggleRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 10)

                textOnlyModeToggleRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 10)

                soundEffectsToggleRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 10)

                wakeWordListeningToggleRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 10)

                proactiveObservationToggleRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 10)

                sessionMemoryToggleRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 10)

                nestToggleRow
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 10)

                dmFarzaButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 420)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Koko")
                    .font(.pixel(size: 20))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.pixel(size: 16))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hold Control+Option to talk.")
                    .font(.pixel(size: 16))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Hit Option+Space to type next to Koko.")
                    .font(.pixel(size: 16))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("Ctrl+Shift+T toggles text-only replies.")
                    .font(.pixel(size: 16))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.pixel(size: 16))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.pixel(size: 14))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Koko.")
                .font(.pixel(size: 16))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Koko.")
                    .font(.pixel(size: 14))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Koko.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.pixel(size: 14))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Koko will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.pixel(size: 14))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.pixel(size: 20))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.pixel(size: 20))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.pixel(size: 16))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.pixel(size: 16))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.pixel(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.pixel(size: 16))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.pixel(size: 16))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.pixel(size: 16))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Session Toggle

    private var sessionToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: companionManager.isSessionActive ? "record.circle" : "stop.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(companionManager.isSessionActive ? DS.Colors.overlayCursorRed : DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Session")
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isSessionActive },
                set: { companionManager.setSessionActive($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.overlayCursorRed)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Text Only Mode Toggle

    /// Toggle for text-only response mode. When on, Koko's replies
    /// stream into a scrollable text panel next to the bird instead
    /// of being spoken aloud via TTS. Also toggled globally via
    /// Ctrl+Shift+T.
    private var textOnlyModeToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.pixel(size: 16))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Text-only replies")
                        .font(.pixel(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { companionManager.isTextOnlyMode },
                    set: { companionManager.setTextOnlyMode($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
            }

            Text("Toggle anytime with Ctrl+Shift+T.")
                .font(.pixel(size: 14))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.leading, 24)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Wake Word Toggle

    /// Opt-in toggle for the always-on "Hey Koko" wake word listener.
    /// Off by default — always-listening is a meaningful escalation of
    /// the app's privacy surface and should be an explicit user choice.
    private var wakeWordListeningToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "ear")
                        .font(.pixel(size: 16))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Always listen for \"Hey Koko\"")
                        .font(.pixel(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { companionManager.isWakeWordListeningEnabled },
                    set: { companionManager.setWakeWordListeningEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
            }

            Text("On-device only — audio never leaves your Mac.")
                .font(.pixel(size: 14))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.leading, 24)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Sound Effects Toggle

    private var soundEffectsToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.pixel(size: 16))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Sound effects")
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.kokoSoundEffects.isEnabled },
                set: { companionManager.kokoSoundEffects.isEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Proactive Observation Toggle

    private var proactiveObservationToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                        .font(.pixel(size: 16))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Proactive observations")
                        .font(.pixel(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { companionManager.kokoProactiveObserver.isEnabled },
                    set: { companionManager.kokoProactiveObserver.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
            }

            HStack(spacing: 6) {
                Text("Every")
                    .font(.pixel(size: 14))
                    .foregroundColor(DS.Colors.textTertiary)

                Stepper(
                    "\(companionManager.kokoProactiveObserver.intervalMinutes) min",
                    value: Binding(
                        get: { companionManager.kokoProactiveObserver.intervalMinutes },
                        set: { companionManager.kokoProactiveObserver.intervalMinutes = $0 }
                    ),
                    in: 1...30
                )
                .font(.pixel(size: 14))
                .foregroundColor(DS.Colors.textTertiary)
                .labelsHidden()

                Text("\(companionManager.kokoProactiveObserver.intervalMinutes) min")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Session Memory Toggle

    private var sessionMemoryToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.pixel(size: 16))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Remember across sessions")
                        .font(.pixel(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { companionManager.kokoMemoryManager.isEnabled },
                    set: { companionManager.kokoMemoryManager.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
            }

            HStack(spacing: 12) {
                Text("Stored in memory.md — local only.")
                    .font(.pixel(size: 14))
                    .foregroundColor(DS.Colors.textTertiary)

                Button(action: {
                    companionManager.kokoMemoryManager.openMemoryFileInEditor()
                }) {
                    Text("Edit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Nest Toggle

    private var nestToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "leaf")
                        .font(.pixel(size: 16))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Nest when idle")
                        .font(.pixel(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { companionManager.kokoNest.isEnabled },
                    set: { companionManager.kokoNest.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
            }

            HStack(spacing: 6) {
                Text("After")
                    .font(.pixel(size: 14))
                    .foregroundColor(DS.Colors.textTertiary)

                Stepper(
                    "\(companionManager.kokoNest.idleMinutes) min",
                    value: Binding(
                        get: { companionManager.kokoNest.idleMinutes },
                        set: { companionManager.kokoNest.idleMinutes = $0 }
                    ),
                    in: 1...30
                )
                .font(.pixel(size: 14))
                .foregroundColor(DS.Colors.textTertiary)
                .labelsHidden()

                Text("\(companionManager.kokoNest.idleMinutes) min idle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.pixel(size: 16))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.pixel(size: 16))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.pixel(size: 18))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.pixel(size: 18))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-7")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - DM Farza Button

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/farzatv") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.pixel(size: 16))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? DM me")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — I read every message.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Koko")
                        .font(.pixel(size: 16))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.pixel(size: 16))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}
