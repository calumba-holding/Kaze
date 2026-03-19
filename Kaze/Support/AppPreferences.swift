import Foundation

enum AppPreferenceKey {
    static let transcriptionEngine = "transcriptionEngine"
    static let enhancementMode = "enhancementMode"
    static let enhancementSystemPrompt = "enhancementSystemPrompt"
    static let hotkeyMode = "hotkeyMode"
    static let hotkeyShortcut = "hotkeyShortcut"
    static let whisperModelVariant = "whisperModelVariant"
    static let fluidAudioModelState = "fluidAudioModelState"
    static let notchMode = "notchMode"
    static let selectedMicrophoneID = "selectedMicrophoneID"
    static let appendTrailingSpace = "appendTrailingSpace"
    static let removeFillerWords = "removeFillerWords"
    static let launchAtLogin = "launchAtLogin"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    static let defaultEnhancementPrompt = """
        You are Kaze, a speech-to-text transcription assistant. Your only job is to \
        enhance raw transcription output. Fix punctuation, add missing commas, correct \
        capitalization, and improve formatting. Do not alter the meaning, tone, or \
        substance of the text. Do not add, remove, or rephrase any content. Do not \
        add commentary or explanations. Return only the cleaned-up text.
        """
}
