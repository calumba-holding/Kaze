import Foundation
import AVFoundation
import Combine
import WhisperKit

/// Manages Whisper model download state, exposed to the settings UI.
@MainActor
class WhisperModelManager: ObservableObject {
    enum ModelState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case loading
        case ready
        case error(String)
    }

    @Published var state: ModelState = .notDownloaded

    /// Path where models are stored in Application Support.
    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.fayazahmed.Kaze/WhisperModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The variant to download. "tiny" is ~75MB and fast on all Apple Silicon.
    static let modelVariant = "tiny"

    private var whisperKit: WhisperKit?

    init() {
        // Check if model is already downloaded
        checkExistingModel()
    }

    func checkExistingModel() {
        let modelDir = Self.modelDirectory
        let fm = FileManager.default

        // Look for any subfolder that contains the model files
        if let contents = try? fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil),
           contents.contains(where: { url in
               let name = url.lastPathComponent.lowercased()
               return name.contains("whisper") && url.hasDirectoryPath
           }) {
            state = .downloaded
        } else {
            // Also check if WhisperKit's default download location has it
            let hubDir = modelDir.appendingPathComponent("huggingface")
            if fm.fileExists(atPath: hubDir.path) {
                state = .downloaded
            } else {
                state = .notDownloaded
            }
        }
    }

    /// Downloads the Whisper tiny model. Progress updates are published.
    func downloadModel() async {
        guard case .notDownloaded = state else { return }

        state = .downloading(progress: 0)

        do {
            let modelFolder = try await WhisperKit.download(
                variant: Self.modelVariant,
                downloadBase: Self.modelDirectory,
                progressCallback: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .downloading(progress: progress.fractionCompleted)
                    }
                }
            )

            // Store the path for later
            UserDefaults.standard.set(modelFolder.path, forKey: "whisperModelPath")
            state = .downloaded
        } catch {
            state = .error("Download failed: \(error.localizedDescription)")
        }
    }

    /// Initializes WhisperKit with the downloaded model. Returns the ready instance.
    func loadModel() async throws -> WhisperKit {
        if let existing = whisperKit {
            return existing
        }

        state = .loading

        // Try stored path first
        let modelPath: String? = UserDefaults.standard.string(forKey: "whisperModelPath")

        let config = WhisperKitConfig(
            model: Self.modelVariant,
            downloadBase: Self.modelDirectory,
            modelFolder: modelPath,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: modelPath == nil // download if we don't have a stored path
        )

        let kit = try await WhisperKit(config)
        whisperKit = kit
        state = .ready
        return kit
    }

    /// Deletes the downloaded model files.
    func deleteModel() {
        whisperKit = nil
        let modelDir = Self.modelDirectory
        try? FileManager.default.removeItem(at: modelDir)
        UserDefaults.standard.removeObject(forKey: "whisperModelPath")
        state = .notDownloaded
    }

    /// The cached WhisperKit instance, if loaded.
    var loadedKit: WhisperKit? { whisperKit }

    /// Size of the downloaded model on disk.
    var modelSizeOnDisk: String {
        let modelDir = Self.modelDirectory
        guard let size = try? FileManager.default.allocatedSizeOfDirectory(at: modelDir), size > 0 else {
            return ""
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - WhisperTranscriber

/// Transcriber that uses WhisperKit (OpenAI Whisper) for speech recognition.
/// Records audio into a buffer while the hotkey is held, then transcribes all at once on release.
@MainActor
class WhisperTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    var onTranscriptionFinished: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var audioBuffer: [Float] = []
    private let modelManager: WhisperModelManager

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
    }

    func requestPermissions() async -> Bool {
        // Whisper only needs microphone access (no SFSpeechRecognizer authorization needed)
        let micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        return micStatus
    }

    func startRecording() {
        guard !isRecording else { return }

        audioBuffer = []
        transcribedText = ""
        audioLevel = 0

        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // We need 16kHz mono for Whisper. We'll convert at the end.
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self else { return }

                // Collect raw audio for later transcription
                if let channelData = buffer.floatChannelData?[0] {
                    let frameLength = Int(buffer.frameLength)
                    let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                    self.audioBuffer.append(contentsOf: samples)

                    // Compute audio level for waveform visualization
                    if frameLength > 0 {
                        var rms: Float = 0
                        for i in 0..<frameLength {
                            rms += channelData[i] * channelData[i]
                        }
                        rms = sqrt(rms / Float(frameLength))
                        let normalized = min(rms * 20, 1.0)
                        Task { @MainActor [weak self] in
                            self?.audioLevel = normalized
                        }
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            print("WhisperTranscriber: Failed to start recording: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        // Now transcribe the collected audio
        let capturedAudio = audioBuffer
        audioBuffer = []

        guard !capturedAudio.isEmpty else {
            onTranscriptionFinished?("")
            return
        }

        Task {
            await transcribeAudio(capturedAudio)
        }
    }

    private func transcribeAudio(_ samples: [Float]) async {
        do {
            let kit = try await modelManager.loadModel()

            // Resample to 16kHz mono if the input format differs
            let inputNode = audioEngine.inputNode
            let inputSampleRate = inputNode.outputFormat(forBus: 0).sampleRate
            let targetSampleRate = Double(WhisperKit.sampleRate) // 16000

            let audioForWhisper: [Float]
            if abs(inputSampleRate - targetSampleRate) > 1.0 {
                audioForWhisper = resample(samples, from: inputSampleRate, to: targetSampleRate)
            } else {
                audioForWhisper = samples
            }

            let results: [TranscriptionResult] = try await kit.transcribe(audioArray: audioForWhisper)
            let text = results.compactMap { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

            transcribedText = text
            onTranscriptionFinished?(text)
        } catch {
            print("WhisperTranscriber: Transcription failed: \(error)")
            onTranscriptionFinished?("")
        }
    }

    /// Simple linear resampling from one sample rate to another.
    private func resample(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = targetSampleRate / sourceSampleRate
        let outputLength = Int(Double(samples.count) * ratio)
        var output = [Float](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            let srcIndex = Double(i) / ratio
            let srcIndexFloor = Int(srcIndex)
            let fraction = Float(srcIndex - Double(srcIndexFloor))

            if srcIndexFloor + 1 < samples.count {
                output[i] = samples[srcIndexFloor] * (1 - fraction) + samples[srcIndexFloor + 1] * fraction
            } else if srcIndexFloor < samples.count {
                output[i] = samples[srcIndexFloor]
            }
        }

        return output
    }
}

// MARK: - FileManager helper

extension FileManager {
    /// Calculates the total allocated size of a directory and its contents.
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        var totalSize: UInt64 = 0
        let enumerator = self.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            totalSize += UInt64(resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize ?? 0)
        }
        return totalSize
    }
}
