import Foundation
import Combine

// MARK: - TranscriptionRecord

struct TranscriptionRecord: Codable, Identifiable {
    let id: UUID
    let text: String
    let timestamp: Date
    let engine: String       // "dictation" or "whisper"
    let wasEnhanced: Bool

    init(text: String, engine: TranscriptionEngine, wasEnhanced: Bool) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.engine = engine.rawValue
        self.wasEnhanced = wasEnhanced
    }
}

// MARK: - Serial Disk Writer

/// A single-writer actor that serializes all JSON persistence.
/// Each write awaits the previous one, and a short debounce coalesces rapid mutations
/// so only the latest snapshot hits disk.
actor SerialDiskWriter<T: Encodable> {
    private let url: URL
    private var pendingValue: T?
    private var writeInFlight = false
    private static var debounceNanoseconds: UInt64 { 150_000_000 } // 150ms

    init(url: URL) {
        self.url = url
    }

    func enqueue(_ value: T) {
        pendingValue = value
        guard !writeInFlight else { return }
        writeInFlight = true
        Task { self.drainLoop() }
    }

    private func drainLoop() {
        while let value = pendingValue {
            pendingValue = nil
            do {
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
            } catch {
                print("SerialDiskWriter: Failed to save to \(url.lastPathComponent): \(error)")
            }
            // Short debounce: if another write was enqueued during encoding, coalesce.
            if pendingValue == nil {
                break
            }
        }
        writeInFlight = false
    }
}

// MARK: - TranscriptionHistoryManager

/// Manages a persistent history of the last 50 transcriptions.
/// Stored as a JSON file in Application Support.
@MainActor
class TranscriptionHistoryManager: ObservableObject {
    @Published private(set) var records: [TranscriptionRecord] = []

    private static let maxRecords = 50
    private let diskWriter: SerialDiskWriter<[TranscriptionRecord]>

    private static var historyFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.fayazahmed.Kaze", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        diskWriter = SerialDiskWriter(url: Self.historyFileURL)
        loadFromDisk()
    }

    /// Adds a new transcription record. Keeps only the most recent 50.
    func addRecord(_ record: TranscriptionRecord) {
        guard !record.text.isEmpty else { return }
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        saveToDisk()
    }

    /// Deletes a single record by ID.
    func deleteRecord(id: UUID) {
        records.removeAll { $0.id == id }
        saveToDisk()
    }

    /// Clears all history.
    func clearHistory() {
        records.removeAll()
        saveToDisk()
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let snapshot = self.records
        Task { await diskWriter.enqueue(snapshot) }
    }

    private func loadFromDisk() {
        let url = Self.historyFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            records = try JSONDecoder().decode([TranscriptionRecord].self, from: data)
        } catch {
            print("TranscriptionHistory: Failed to load: \(error)")
            records = []
        }
    }
}

// MARK: - Static Relative Date Formatting

extension Date {
    /// Cached DateFormatter to avoid re-creating one per cell (Fix #7).
    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Returns a static relative string like "Just now", "3 min ago", "2 hr ago", "Yesterday", etc.
    /// Unlike SwiftUI's `Text(_:style: .relative)`, this does not live-update.
    var relativeString: String {
        let now = Date()
        let seconds = Int(now.timeIntervalSince(self))

        if seconds < 60 {
            return "Just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) min ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) hr ago"
        }

        let days = hours / 24
        if days == 1 {
            return "Yesterday"
        }
        if days < 7 {
            return "\(days) days ago"
        }

        return Self.mediumDateFormatter.string(from: self)
    }
}
