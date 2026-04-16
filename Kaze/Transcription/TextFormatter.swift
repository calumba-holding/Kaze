import Foundation
import FoundationModels

/// Uses Apple Intelligence (on-device Foundation Models) to add structural
/// formatting (line breaks, paragraphs, lists) to raw transcription output.
/// This is an experimental feature that post-processes text without altering words.
@available(macOS 26.0, *)
@MainActor
class TextFormatter {

    /// Whether Apple Intelligence is available on this device.
    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Adds structural formatting to raw transcribed text by detecting topic
    /// changes, enumerations, and spoken formatting cues.
    /// - Parameter rawText: The transcription output to format.
    /// - Returns: The formatted text with appropriate line breaks and list markers.
    func format(_ rawText: String) async throws -> String {
        guard TextFormatter.isAvailable else {
            return rawText
        }

        let session = LanguageModelSession(
            instructions: AppPreferenceKey.smartFormattingPrompt
        )

        let response = try await session.respond(
            to: "Format this transcription:\n\n\(rawText)"
        )

        let formatted = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatted.isEmpty ? rawText : formatted
    }
}
