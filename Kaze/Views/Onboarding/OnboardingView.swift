import SwiftUI
import AppKit
import Carbon
import AVFoundation
import Speech

// MARK: - Onboarding View

struct OnboardingView: View {
    @State private var currentStep = 0
    @State private var hotkeyShortcut = HotkeyShortcut.default
    @AppStorage(AppPreferenceKey.transcriptionEngine) private var engineRaw = TranscriptionEngine.parakeet.rawValue
    @AppStorage(AppPreferenceKey.hotkeyMode) private var hotkeyModeRaw = HotkeyMode.holdToTalk.rawValue

    // Permission states
    @State private var microphoneGranted = false
    @State private var accessibilityGranted = false
    @State private var permissionPollTimer: Timer?

    // Model managers
    @ObservedObject var whisperModelManager: WhisperModelManager
    @ObservedObject var parakeetModelManager: FluidAudioModelManager
    @ObservedObject var qwenModelManager: FluidAudioModelManager
    @StateObject private var hotkeyRecorder = HotkeyShortcutRecorder()

    /// The hosting window, used to animate center-origin resize on step transitions.
    weak var window: NSWindow?

    var onComplete: () -> Void

    private let totalSteps = 6

    /// Whether we've expanded beyond the initial animated card size.
    @State private var isExpanded = false

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .parakeet
    }

    /// Whether the engine step requires a model download and the model isn't already downloaded.
    private var needsModelDownload: Bool {
        selectedEngine.requiresModelDownload && !isModelReady
    }

    /// Whether the selected model is currently downloading.
    private var isModelDownloading: Bool {
        selectedEngine.isModelDownloading(
            whisperManager: whisperModelManager,
            parakeetManager: parakeetModelManager,
            qwenManager: qwenModelManager
        )
    }

    /// Whether the selected model has been downloaded (or doesn't need one).
    private var isModelReady: Bool {
        selectedEngine.isModelReady(
            whisperManager: whisperModelManager,
            parakeetManager: parakeetModelManager,
            qwenManager: qwenModelManager
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Content area -- all steps live in the same view tree
            Group {
                switch currentStep {
                case 0:
                    animatedWelcomeStep
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .scale(scale: 0.85, anchor: .center).combined(with: .opacity)
                        ))
                case 1: permissionsStep
                case 2: hotkeyStep
                case 3: engineStep
                case 4: modelDownloadStep
                case 5: doneStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            // Navigation bar -- hidden during step 0
            if isExpanded {
                Divider()

                HStack {
                    // Step indicators
                    HStack(spacing: 6) {
                        ForEach(0..<totalSteps, id: \.self) { step in
                            Circle()
                                .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }

                    Spacer()

                    if currentStep > 1 && currentStep < totalSteps - 1 {
                        Button("Back") {
                            hotkeyRecorder.stop()
                            if currentStep == 5 && !selectedEngine.requiresModelDownload {
                                currentStep = 3
                            } else {
                                currentStep -= 1
                            }
                        }
                        .controlSize(.regular)
                    }

                    if currentStep < totalSteps - 1 {
                        Button("Continue") {
                            hotkeyRecorder.stop()
                            if currentStep == 2 {
                                hotkeyShortcut.saveToDefaults()
                            }
                            if currentStep == 3 {
                                if !selectedEngine.requiresModelDownload {
                                    currentStep = 5
                                    return
                                }
                            }
                            currentStep += 1
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                        .disabled(currentStep == 4 && isModelDownloading)
                    } else {
                        Button("Get Started") {
                            hotkeyShortcut.saveToDefaults()
                            UserDefaults.standard.set(true, forKey: AppPreferenceKey.hasCompletedOnboarding)
                            onComplete()
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(
            width: isExpanded ? 480 : 370,
            height: isExpanded ? 540 : 450
        )
        .background(.windowBackground)
        .clipShape(.rect(cornerRadius: 30))
        .gesture(WindowDragGesture())
        .onAppear {
            hotkeyRecorder.onShortcutRecorded = { shortcut in
                hotkeyShortcut = shortcut
            }
        }
        .onDisappear {
            hotkeyRecorder.stop()
            stopPermissionPolling()
        }
    }

    /// Animates the NSWindow frame from its center so the expansion looks symmetric.
    private func expandFromCenter() {
        guard let window else {
            withAnimation(.easeInOut(duration: 0.35)) {
                isExpanded = true
            }
            return
        }
        let oldFrame = window.frame
        let newSize = NSSize(width: 480, height: 540)
        let newOrigin = NSPoint(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.midY - newSize.height / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: newSize)
        withAnimation(.easeInOut(duration: 0.35)) {
            isExpanded = true
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }

    // MARK: - Step 0: Animated Welcome

    private var animatedWelcomeStep: some View {
        AnimatedOnboardingView(
            foregroundColor: .white,
            tint: .accentColor
        ) { isAnimating in
            if let icon = NSImage(named: "kaze-icon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 120)
                    .clipShape(.rect(cornerRadius: 24, style: .continuous))
                    .scaleEffect(isAnimating ? 0.65 : 1)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 100))
                    .foregroundStyle(.white)
                    .blendMode(.softLight)
                    .scaleEffect(isAnimating ? 0.5 : 1)
            }
        } content: { isAnimating in
            VStack(spacing: 15) {
                VStack(spacing: 6) {
                    Text("Welcome to Kaze")
                        .font(.title.bold())

                    Text("Speech-to-text that runs entirely on your Mac.\nNo cloud, no subscription, no data leaves your device.")
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .multilineTextAlignment(.center)
                }

                Button {
                    expandFromCenter()
                    withAnimation(.easeInOut(duration: 0.35)) {
                        currentStep = 1
                    }
                } label: {
                    Text("Continue")
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 230)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.gradient, in: .capsule)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.top, 45)
        } onClose: {
            onComplete()
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()

            if let icon = NSImage(named: "kaze-icon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
            } else {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)
            }

            Text("Welcome to Kaze")
                .font(.title.bold())

            Text("Speech-to-text that runs entirely on your Mac.\nNo cloud, no subscription, no data leaves your device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Step 2: Permissions

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Permissions")
                .font(.title2.bold())

            Text("Kaze needs a few permissions to work.\nGrant them below, then continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 12) {
                // Microphone Permission
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required to capture your voice for transcription.",
                    isGranted: microphoneGranted,
                    action: requestMicrophonePermission
                )

                // Accessibility Permission
                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Required to detect your global hotkey.",
                    isGranted: accessibilityGranted,
                    action: requestAccessibilityPermission
                )
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .onAppear {
            checkPermissionStates()
            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 32, height: 32)
                .foregroundStyle(isGranted ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Grant") {
                    action()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isGranted ? Color.green.opacity(0.06) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isGranted ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func checkPermissionStates() {
        // Check microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        default:
            microphoneGranted = false
        }

        // Check accessibility (silent check, no prompt)
        accessibilityGranted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
    }

    private func requestMicrophonePermission() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                microphoneGranted = granted
            }
        }
    }

    private func requestAccessibilityPermission() {
        // This opens the Accessibility pane in System Settings and prompts the user
        // We use the prompt option to show the system dialog
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = trusted
        // If not yet trusted, the system will show a dialog. We poll for changes.
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                checkPermissionStates()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Step 3: Hotkey Setup

    private var hotkeyStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Set Your Hotkey")
                .font(.title2.bold())

            Text("Choose how you want to trigger Kaze.")
                .font(.body)
                .foregroundStyle(.secondary)

            // Mode picker
            VStack(alignment: .leading, spacing: 8) {
                Picker("Mode", selection: $hotkeyModeRaw) {
                    ForEach(HotkeyMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 200)

                let selectedMode = HotkeyMode(rawValue: hotkeyModeRaw) ?? .holdToTalk
                Text(selectedMode.description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)

            // Hotkey display + record
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(hotkeyShortcut.displayTokens, id: \.self) { token in
                        OnboardingKeyCapView(token)
                    }
                }

                Button(hotkeyRecorder.isRecording ? "Press keys..." : "Change") {
                    if hotkeyRecorder.isRecording {
                        hotkeyRecorder.stop()
                    } else {
                        hotkeyRecorder.start()
                    }
                }
                .controlSize(.small)

                Button("Reset") {
                    hotkeyShortcut = .default
                    hotkeyRecorder.stop()
                }
                .controlSize(.small)
            }

            if hotkeyRecorder.isRecording {
                Text("Press a key combination with at least one modifier. Press Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 40)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
    }

    // MARK: - Step 4: Engine Selection

    private var engineStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Choose an Engine")
                .font(.title2.bold())

            Text("You can change this later in Settings.\nAI engines require a one-time model download.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                // Order: Parakeet first (recommended), then others
                ForEach(TranscriptionEngine.onboardingOrder, id: \.self) { engine in
                    Button {
                        engineRaw = engine.rawValue
                    } label: {
                        HStack(spacing: 10) {
                            engineIconView(engine)
                                .frame(width: 20)
                                .foregroundStyle(engineRaw == engine.rawValue ? .white : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(engine.title)
                                        .font(.system(size: 13, weight: .medium))
                                    if engine == .parakeet {
                                        Text("Recommended")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                    .fill(engineRaw == engine.rawValue ? Color.white.opacity(0.2) : Color.accentColor.opacity(0.12))
                                            )
                                            .foregroundStyle(engineRaw == engine.rawValue ? .white : .accentColor)
                                    }
                                }
                                Text(engine.onboardingDescription)
                                    .font(.caption2)
                                    .lineLimit(2)
                                    .opacity(0.8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if engineRaw == engine.rawValue {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(engineRaw == engine.rawValue ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(engineRaw == engine.rawValue ? .white : .primary)
                }
            }
            .padding(.horizontal, 60)

            Spacer()
        }
    }

    // MARK: - Step 5: Model Download

    private var modelDownloadStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Download Model")
                .font(.title2.bold())

            Text("\(selectedEngine.title) requires a model download.\nThis only needs to happen once.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Model download status
            VStack(spacing: 12) {
                modelDownloadStatusView
            }
            .padding(.horizontal, 60)

            Spacer()
        }
    }

    @ViewBuilder
    private var modelDownloadStatusView: some View {
        switch selectedEngine {
        case .whisper:
            onboardingWhisperStatus
        case .parakeet:
            onboardingFluidAudioStatus(manager: parakeetModelManager, model: .parakeet)
        case .qwen:
            onboardingFluidAudioStatus(manager: qwenModelManager, model: .qwen)
        default:
            Text("No download required.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var onboardingWhisperStatus: some View {
        switch whisperModelManager.state {
        case .notDownloaded:
            VStack(spacing: 10) {
                Text("Whisper \(whisperModelManager.selectedVariant.title) (\(whisperModelManager.selectedVariant.sizeDescription))")
                    .font(.system(size: 13, weight: .medium))
                Button("Download Model") {
                    Task { await whisperModelManager.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .frame(maxWidth: 240)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    whisperModelManager.cancelDownload()
                }
                .controlSize(.small)
            }

        case .downloaded, .ready, .loading:
            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)

        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    whisperModelManager.deleteModel()
                    Task { await whisperModelManager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func onboardingFluidAudioStatus(manager: FluidAudioModelManager, model: FluidAudioModel) -> some View {
        switch manager.state {
        case .notDownloaded:
            VStack(spacing: 10) {
                Text("\(model.title) (\(model.sizeDescription))")
                    .font(.system(size: 13, weight: .medium))
                Button("Download Model") {
                    Task { await manager.downloadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

        case .downloading(let progress):
            VStack(spacing: 8) {
                ProgressView(value: max(progress, 0))
                    .frame(maxWidth: 240)
                Text("Downloading \(model.title)... \(Int(max(progress, 0) * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel", role: .destructive) {
                    manager.cancelDownload()
                }
                .controlSize(.small)
            }

        case .downloaded, .ready, .loading:
            Label("Model downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)

        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry") {
                    manager.deleteModel()
                    Task { await manager.downloadModel() }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Step 6: Done

    private var doneStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title2.bold())

            let shortcutDisplay = hotkeyShortcut.displayString
            let modeDisplay = (HotkeyMode(rawValue: hotkeyModeRaw) ?? .holdToTalk).title.lowercased()

            Text("Press **\(shortcutDisplay)** (\(modeDisplay)) to start dictating.\nKaze lives in your menu bar.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func engineIconView(_ engine: TranscriptionEngine) -> some View {
        switch engine {
        case .dictation:
            Text("\u{F8FF}")
                .font(.system(size: 16))
        case .whisper:
            Image("openai-icon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        case .parakeet:
            Image("nvidia-icon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        case .qwen:
            Image("qwen-icon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
    }

}

// MARK: - Onboarding Key Cap View

private struct OnboardingKeyCapView: View {
    let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 14, weight: .medium))
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}
