import AppKit
import Combine

@MainActor
final class HotkeyShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false

    private var monitor: Any?
    private var recordedModifiersUnion: HotkeyShortcut.Modifiers = []
    var onShortcutRecorded: ((HotkeyShortcut) -> Void)?

    init(onShortcutRecorded: ((HotkeyShortcut) -> Void)? = nil) {
        self.onShortcutRecorded = onShortcutRecorded
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start() {
        stop()
        isRecording = true
        recordedModifiersUnion = []

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        isRecording = false
        recordedModifiersUnion = []
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }

        if event.type == .flagsChanged {
            let modifiers = HotkeyShortcut.Modifiers(from: event.modifierFlags)

            if !modifiers.isEmpty {
                recordedModifiersUnion.formUnion(modifiers)
                return nil
            }

            if !recordedModifiersUnion.isEmpty {
                finish(with: HotkeyShortcut(modifiers: recordedModifiersUnion, keyCode: nil))
                return nil
            }

            return nil
        }

        if event.keyCode == 53 {
            stop()
            return nil
        }

        let modifiers = HotkeyShortcut.Modifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return nil
        }

        finish(with: HotkeyShortcut(modifiers: modifiers, keyCode: Int(event.keyCode)))
        return nil
    }

    private func finish(with shortcut: HotkeyShortcut) {
        onShortcutRecorded?(shortcut)
        stop()
    }
}
