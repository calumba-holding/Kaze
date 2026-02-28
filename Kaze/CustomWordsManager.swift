import Foundation
import Combine

/// Manages a user-defined list of custom words, names, abbreviations, and terms
/// that should be recognized accurately during transcription.
/// Stored as a JSON file in Application Support.
@MainActor
class CustomWordsManager: ObservableObject {
    @Published private(set) var words: [String] = []

    private static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.fayazahmed.Kaze", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom_words.json")
    }

    init() {
        loadFromDisk()
    }

    /// Adds a new word if it's not empty and not already in the list.
    func addWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Case-insensitive duplicate check
        guard !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        words.append(trimmed)
        saveToDisk()
    }

    /// Removes a word at the given index.
    func removeWord(at index: Int) {
        guard words.indices.contains(index) else { return }
        words.remove(at: index)
        saveToDisk()
    }

    /// Removes a word by value.
    func removeWord(_ word: String) {
        words.removeAll { $0 == word }
        saveToDisk()
    }

    /// All words joined as a prompt string for Whisper.
    /// Whisper uses an initial text prompt to bias recognition toward these terms.
    var whisperPrompt: String {
        words.joined(separator: ", ")
    }

    // MARK: - Persistence

    // Fix #11: Move synchronous disk I/O off the main thread

    private func saveToDisk() {
        let words = self.words
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(words)
                try data.write(to: url, options: .atomic)
            } catch {
                print("CustomWordsManager: Failed to save: \(error)")
            }
        }
    }

    private func loadFromDisk() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // For init-time load, keep synchronous so words are available immediately
        do {
            let data = try Data(contentsOf: url)
            words = try JSONDecoder().decode([String].self, from: data)
        } catch {
            print("CustomWordsManager: Failed to load: \(error)")
            words = []
        }
    }
}
