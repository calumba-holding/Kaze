import SwiftUI
import AppKit

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case dictation
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Direct Dictation"
        case .whisper: return "Whisper (OpenAI)"
        }
    }

    var description: String {
        switch self {
        case .dictation: return "Uses Apple's built-in speech recognition. Works immediately with no setup."
        case .whisper: return "Uses OpenAI's Whisper model running locally on your Mac. Requires a one-time download."
        }
    }
}

enum EnhancementMode: String, CaseIterable, Identifiable {
    case off
    case appleIntelligence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }
}

enum AppPreferenceKey {
    static let transcriptionEngine = "transcriptionEngine"
    static let enhancementMode = "enhancementMode"
    static let enhancementSystemPrompt = "enhancementSystemPrompt"

    static let defaultEnhancementPrompt = """
        You are Kaze, a speech-to-text transcription assistant. Your only job is to \
        enhance raw transcription output. Fix punctuation, add missing commas, correct \
        capitalization, and improve formatting. Do not alter the meaning, tone, or \
        substance of the text. Do not add, remove, or rephrase any content. Do not \
        add commentary or explanations. Return only the cleaned-up text.
        """
}

@main
struct KazeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ContentView(whisperModelManager: appDelegate.whisperModelManager)
                .frame(width: 460)
                .padding()
        }
    }
}

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let speechTranscriber = SpeechTranscriber()
    private var whisperTranscriber: WhisperTranscriber?
    let whisperModelManager = WhisperModelManager()

    private let hotkeyManager = HotkeyManager()
    private let overlayWindow = RecordingOverlayWindow()
    private let overlayState = OverlayState()
    private var statusItem: NSStatusItem?

    private var enhancer: TextEnhancer?
    private var settingsWindowController: NSWindowController?

    var transcriptionEngine: TranscriptionEngine {
        get {
            let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.transcriptionEngine)
            return TranscriptionEngine(rawValue: raw ?? "") ?? .dictation
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.transcriptionEngine)
        }
    }

    private var enhancementMode: EnhancementMode {
        get {
            let raw = UserDefaults.standard.string(forKey: AppPreferenceKey.enhancementMode)
            return EnhancementMode(rawValue: raw ?? "") ?? .off
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppPreferenceKey.enhancementMode)
        }
    }

    private var isSessionActive = false

    /// Returns the currently active transcriber based on the user's engine preference.
    private var activeTranscriber: (any TranscriberProtocol)? {
        switch transcriptionEngine {
        case .dictation:
            return speechTranscriber
        case .whisper:
            if whisperTranscriber == nil {
                whisperTranscriber = WhisperTranscriber(modelManager: whisperModelManager)
            }
            return whisperTranscriber
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an accessory so no Dock icon appears
        NSApp.setActivationPolicy(.accessory)
        migrateLegacyPreferences()

        // Set up Apple Intelligence enhancer if available
        if #available(macOS 26.0, *), TextEnhancer.isAvailable {
            enhancer = TextEnhancer()
        }

        // Menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            if let icon = NSImage(named: "kaze-icon") {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Kaze")
            }
            button.image?.accessibilityDescription = "Kaze"
        }
        buildMenu()

        Task {
            let granted = await speechTranscriber.requestPermissions()
            if !granted {
                showPermissionAlert()
                return
            }
            setupHotkey()
        }
    }

    private func migrateLegacyPreferences() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: AppPreferenceKey.enhancementMode) == nil,
           defaults.object(forKey: "aiEnhanceEnabled") != nil {
            let oldEnabled = defaults.bool(forKey: "aiEnhanceEnabled")
            enhancementMode = oldEnabled ? .appleIntelligence : .off
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Kaze", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func openSettings() {
        if let window = settingsWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = ContentView(whisperModelManager: whisperModelManager)
            .frame(width: 460)
            .padding()
        let hostingController = NSHostingController(rootView: contentView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Kaze Settings"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    private func setupHotkey() {
        hotkeyManager.onKeyDown = { [weak self] in
            self?.beginRecording()
        }
        hotkeyManager.onKeyUp = { [weak self] in
            self?.endRecording()
        }
        hotkeyManager.start()
    }

    private func beginRecording() {
        guard !isSessionActive else { return }

        // If Whisper is selected but the model isn't downloaded yet, fall back to dictation
        if transcriptionEngine == .whisper {
            let modelState = whisperModelManager.state
            if case .notDownloaded = modelState {
                print("Whisper model not downloaded, falling back to Direct Dictation")
                // Still proceed with dictation for this session
            } else if case .error = modelState {
                print("Whisper model in error state, falling back to Direct Dictation")
            }
        }

        isSessionActive = true

        // Use the appropriate transcriber
        if transcriptionEngine == .whisper, isWhisperReady {
            let whisper = whisperTranscriber ?? WhisperTranscriber(modelManager: whisperModelManager)
            whisperTranscriber = whisper
            whisper.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            overlayState.bind(to: whisper)
            overlayWindow.show(state: overlayState)
            whisper.startRecording()
        } else {
            speechTranscriber.onTranscriptionFinished = { [weak self] (text: String) in
                guard let self else { return }
                self.processTranscription(text)
            }
            overlayState.bind(to: speechTranscriber)
            overlayWindow.show(state: overlayState)
            speechTranscriber.startRecording()
        }
    }

    /// Whether the Whisper model is downloaded and available for use.
    private var isWhisperReady: Bool {
        switch whisperModelManager.state {
        case .downloaded, .ready, .loading:
            return true
        default:
            return false
        }
    }

    private func endRecording() {
        guard isSessionActive else { return }

        if transcriptionEngine == .whisper, isWhisperReady {
            whisperTranscriber?.stopRecording()
            // For Whisper, transcription happens after stop — the overlay stays visible
            // until onTranscriptionFinished fires via processTranscription
            overlayState.isEnhancing = true // Show processing state while Whisper works
        } else {
            speechTranscriber.stopRecording()
            let waitingForAI = enhancementMode == .appleIntelligence && enhancer != nil
            if !waitingForAI {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.overlayWindow.hide()
                    self?.isSessionActive = false
                }
            }
        }
    }

    private func processTranscription(_ rawText: String) {
        // Clear the "processing" state from Whisper
        overlayState.isEnhancing = false

        guard !rawText.isEmpty else {
            overlayWindow.hide()
            isSessionActive = false
            return
        }

        if enhancementMode == .appleIntelligence, let enhancer {
            overlayState.isEnhancing = true
            if transcriptionEngine == .whisper {
                whisperTranscriber?.isEnhancing = true
            } else {
                speechTranscriber.isEnhancing = true
            }
            Task {
                defer {
                    self.overlayState.isEnhancing = false
                    if self.transcriptionEngine == .whisper {
                        self.whisperTranscriber?.isEnhancing = false
                    } else {
                        self.speechTranscriber.isEnhancing = false
                    }
                    self.overlayWindow.hide()
                    self.isSessionActive = false
                }
                do {
                    if #available(macOS 26.0, *) {
                        let prompt = UserDefaults.standard.string(forKey: AppPreferenceKey.enhancementSystemPrompt)
                            ?? AppPreferenceKey.defaultEnhancementPrompt
                        let enhanced = try await enhancer.enhance(rawText, systemPrompt: prompt)
                        self.typeText(enhanced)
                    } else {
                        self.typeText(rawText)
                    }
                } catch {
                    print("AI enhancement failed, using raw text: \(error)")
                    self.typeText(rawText)
                }
            }
        } else {
            typeText(rawText)
            overlayWindow.hide()
            isSessionActive = false
        }
    }

    private func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string) ?? ""
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let vKeyCode: CGKeyCode = 0x09
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        cmdUp?.flags = .maskCommand

        cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if !previous.isEmpty {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    @objc private func quit() {
        hotkeyManager.stop()
        NSApp.terminate(nil)
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = "Kaze needs Microphone and Speech Recognition access. Please grant them in System Settings → Privacy & Security."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
        }
        NSApp.terminate(nil)
    }
}
