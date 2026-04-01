import Foundation
import Combine

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case dictation
    case whisper
    case parakeet

    static let onboardingOrder: [Self] = [.parakeet, .whisper, .dictation]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Direct Dictation"
        case .whisper: return "Whisper (OpenAI)"
        case .parakeet: return "Parakeet v3 (NVIDIA)"
        }
    }

    var description: String {
        switch self {
        case .dictation: return "Uses Apple's built-in speech recognition. Works immediately with no setup."
        case .whisper: return "Uses OpenAI's Whisper model running locally on your Mac. Requires a one-time download."
        case .parakeet: return "NVIDIA's Parakeet TDT 0.6B v3 via CoreML. Top-ranked accuracy, blazing fast. English only."
        }
    }

    var onboardingDescription: String {
        switch self {
        case .parakeet:
            return "Best accuracy, blazing fast. English only. ~600 MB download."
        case .whisper:
            return "OpenAI's Whisper running locally. Multiple sizes available."
        case .dictation:
            return "Apple's built-in speech recognition. No download required."
        }
    }

    var requiresModelDownload: Bool {
        switch self {
        case .dictation:
            return false
        case .whisper, .parakeet:
            return true
        }
    }

    func isModelReady(
        whisperManager: WhisperModelManager,
        parakeetManager: FluidAudioModelManager
    ) -> Bool {
        switch self {
        case .dictation:
            return true
        case .whisper:
            return whisperManager.isAvailableForTranscription
        case .parakeet:
            return parakeetManager.isAvailableForTranscription
        }
    }

    func isModelDownloading(
        whisperManager: WhisperModelManager,
        parakeetManager: FluidAudioModelManager
    ) -> Bool {
        switch self {
        case .dictation:
            return false
        case .whisper:
            return whisperManager.isDownloading
        case .parakeet:
            return parakeetManager.isDownloading
        }
    }
}

enum HotkeyMode: String, CaseIterable, Identifiable {
    case holdToTalk
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdToTalk: return "Hold to Talk"
        case .toggle: return "Press to Toggle"
        }
    }

    var description: String {
        switch self {
        case .holdToTalk: return "Hold the hotkey to record, release to stop."
        case .toggle: return "Press the hotkey once to start, press again to stop."
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
