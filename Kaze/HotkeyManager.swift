import Foundation
import Carbon
import AppKit

/// Monitors the global Option+Command (⌥⌘) hotkey via a CGEvent tap.
/// Supports two modes:
/// - **Hold to Talk**: Press and hold both keys → `onKeyDown`; release either → `onKeyUp`
/// - **Toggle**: First press of combo → `onKeyDown`; second press → `onKeyUp`
@MainActor
class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    /// The current hotkey mode. Can be changed at runtime.
    var mode: HotkeyMode = .holdToTalk

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

    /// Tracks whether a toggle session is active (only used in toggle mode).
    private var isToggleActive = false

    // We track flags-changed events and require both Option and Command.
    private let optionFlagMask: CGEventFlags = .maskAlternate
    private let commandFlagMask: CGEventFlags = .maskCommand

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
            (1 << CGEventType.flagsChanged.rawValue)

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
        guard type == .flagsChanged else { return }

        let flags = event.flags
        let optionIsDown = flags.contains(optionFlagMask)
        let commandIsDown = flags.contains(commandFlagMask)
        let comboIsDown = optionIsDown && commandIsDown

        DispatchQueue.main.async { [self] in
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
    }
}
