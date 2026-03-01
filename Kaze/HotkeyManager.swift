import Foundation
import Carbon
import AppKit

/// Monitors a configurable global hotkey via a CGEvent tap.
/// Supports two modes:
/// - **Hold to Talk**: Press and hold both keys → `onKeyDown`; release either → `onKeyUp`
/// - **Toggle**: First press of combo → `onKeyDown`; second press → `onKeyUp`
@MainActor
class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// The current hotkey mode. Can be changed at runtime.
    var mode: HotkeyMode = .holdToTalk
    var shortcut: HotkeyShortcut = .default

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

    /// Tracks whether a toggle session is active (only used in toggle mode).
    private var isToggleActive = false

    /// `true` if the event tap was successfully created (i.e. Accessibility permission is granted).
    private(set) var isAccessibilityGranted = false

    /// Returns `true` if the app currently has Accessibility permission.
    static func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        )
    }

    @discardableResult
    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleEvent(type: type, event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyManager] Failed to create event tap. Grant Accessibility permission.")
            isAccessibilityGranted = false
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isAccessibilityGranted = true
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Called from the CGEvent tap callback on an arbitrary thread.
    /// Dispatches all mutable state access and callbacks to the main queue
    /// to avoid data races with @MainActor-isolated properties. (Fix #2)
    private func handleEvent(type: CGEventType, event: CGEvent) {
        DispatchQueue.main.async { [self] in
            let currentShortcut = shortcut
            guard currentShortcut.isValid else { return }

            if let keyCode = currentShortcut.keyCode {
                handleKeyBasedShortcut(type: type, event: event, keyCode: keyCode, shortcut: currentShortcut)
            } else {
                handleModifierOnlyShortcut(type: type, event: event, shortcut: currentShortcut)
            }
        }
    }

    private func handleModifierOnlyShortcut(type: CGEventType, event: CGEvent, shortcut: HotkeyShortcut) {
        guard type == .flagsChanged else { return }
        let comboIsDown = shortcut.matchesExactModifiers(event.flags)

        switch mode {
        case .holdToTalk:
            if comboIsDown && !isKeyDown {
                isKeyDown = true
                onKeyDown?()
            } else if !comboIsDown && isKeyDown {
                isKeyDown = false
                onKeyUp?()
            }

        case .toggle:
            // Detect the rising edge: combo was not pressed, now it is
            if comboIsDown && !isKeyDown {
                isKeyDown = true
                if !isToggleActive {
                    // First press: start recording
                    isToggleActive = true
                    onKeyDown?()
                } else {
                    // Second press: stop recording
                    isToggleActive = false
                    onKeyUp?()
                }
            } else if !comboIsDown && isKeyDown {
                // Keys released — just reset the edge detector, don't fire callbacks
                isKeyDown = false
            }
        }
    }

    private func handleKeyBasedShortcut(type: CGEventType, event: CGEvent, keyCode: Int, shortcut: HotkeyShortcut) {
        let eventKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch type {
        case .keyDown:
            // Ignore key repeat so hold mode doesn't retrigger.
            let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) == 1
            guard !isAutoRepeat else { return }
            guard eventKeyCode == keyCode else { return }
            guard shortcut.matchesExactModifiers(event.flags) else { return }

            switch mode {
            case .holdToTalk:
                guard !isKeyDown else { return }
                isKeyDown = true
                onKeyDown?()
            case .toggle:
                guard !isKeyDown else { return }
                isKeyDown = true
                if !isToggleActive {
                    isToggleActive = true
                    onKeyDown?()
                } else {
                    isToggleActive = false
                    onKeyUp?()
                }
            }

        case .keyUp:
            guard eventKeyCode == keyCode else { return }
            if mode == .holdToTalk && isKeyDown {
                isKeyDown = false
                onKeyUp?()
            } else if mode == .toggle {
                isKeyDown = false
            }

        case .flagsChanged:
            // If modifier state changes while the key is held in hold mode,
            // stop as soon as the configured modifiers are no longer held.
            guard mode == .holdToTalk, isKeyDown else { return }
            if !shortcut.matchesExactModifiers(event.flags) {
                isKeyDown = false
                onKeyUp?()
            }

        default:
            return
        }
    }
}
