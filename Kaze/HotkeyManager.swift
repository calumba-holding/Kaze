import Foundation
import Carbon
import AppKit

/// Monitors the global Option+Command (⌥⌘) hotkey via a CGEvent tap.
/// - Press and hold both keys  → calls `onKeyDown`
/// - Release either key        → calls `onKeyUp`
@MainActor
class HotkeyManager {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false

    // We track flags-changed events and require both Option and Command.
    private let optionFlagMask: CGEventFlags = .maskAlternate
    private let commandFlagMask: CGEventFlags = .maskCommand

    func start() {
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
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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

    private func handleEvent(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }

        let flags = event.flags
        let optionIsDown = flags.contains(optionFlagMask)
        let commandIsDown = flags.contains(commandFlagMask)
        let comboIsDown = optionIsDown && commandIsDown

        if comboIsDown && !isKeyDown {
            isKeyDown = true
            Task { @MainActor in self.onKeyDown?() }
        } else if !comboIsDown && isKeyDown {
            isKeyDown = false
            Task { @MainActor in self.onKeyUp?() }
        }
    }
}
