import Foundation
import AVFoundation
import Accelerate
import Combine
import FluidAudio

// MARK: - FluidAudio Model Type

enum FluidAudioModel: String, CaseIterable, Identifiable {
    case parakeet
    case qwen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet: return "Parakeet TDT 0.6B v3"
        case .qwen: return "Qwen3 ASR 0.6B"
        }
    }

    var sizeDescription: String {
        switch self {
        case .parakeet: return "~600 MB"
        case .qwen: return "~2.5 GB"
        }
    }

    var qualityDescription: String {
        switch self {
        case .parakeet: return "Top-ranked accuracy, blazing fast. English only."
        case .qwen: return "Fast multilingual transcription, 30+ languages."
        }
    }

    var provider: String {
        switch self {
        case .parakeet: return "NVIDIA"
        case .qwen: return "Alibaba"
        }
    }

    /// HuggingFace repo ID used for download.
    var repoId: String {
        switch self {
        case .parakeet: return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .qwen: return "FluidInference/qwen3-asr-0.6b-coreml"
        }
    }

    /// Subfolder within the HuggingFace repo (if any).
    var repoSubfolder: String? {
        switch self {
        case .parakeet: return nil
        case .qwen: return "f32"
        }
    }
}

// MARK: - FluidAudioModelManager

/// Manages FluidAudio model download state for Parakeet and Qwen models.
@MainActor
class FluidAudioModelManager: ObservableObject {
    enum ModelState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case loading
        case ready
        case error(String)
    }

    @Published var state: ModelState = .notDownloaded
    /// Cached model size string to avoid recursive directory enumeration in view body (Fix #12).
    @Published private(set) var modelSizeOnDiskCached: String = ""

    let model: FluidAudioModel

    // Loaded runtime objects
    private var parakeetManager: AsrManager?
    private var qwen3Manager: Qwen3AsrManager?
    private var loadTask: Task<Void, any Error>?
    private var downloadTask: Task<Void, Never>?

    init(model: FluidAudioModel) {
        self.model = model
        checkExistingModel()
    }

    /// The default cache directory where FluidAudio stores downloaded models.
    var modelDirectory: URL {
        switch model {
        case .parakeet:
            return AsrModels.defaultCacheDirectory(for: .v3)
        case .qwen:
            return Qwen3AsrModels.defaultCacheDirectory()
        }
    }

    func checkExistingModel() {
        switch model {
        case .parakeet:
            let dir = AsrModels.defaultCacheDirectory(for: .v3)
            if AsrModels.modelsExist(at: dir, version: .v3) {
                state = .downloaded
                refreshModelSizeOnDisk()
            } else {
                state = .notDownloaded
                modelSizeOnDiskCached = ""
            }
        case .qwen:
            let dir = Qwen3AsrModels.defaultCacheDirectory()
            if Qwen3AsrModels.modelsExist(at: dir) {
                state = .downloaded
                refreshModelSizeOnDisk()
            } else {
                state = .notDownloaded
                modelSizeOnDiskCached = ""
            }
        }
    }

    /// Estimated total download size in bytes for progress estimation.
    private var estimatedDownloadBytes: UInt64 {
        switch model {
        case .parakeet: return 600_000_000  // ~600 MB
        case .qwen: return 2_500_000_000    // ~2.5 GB
        }
    }

    /// Downloads the model. Polls directory size to estimate progress since FluidAudio
    /// doesn't expose granular download progress callbacks.
    func downloadModel() async {
        guard case .notDownloaded = state else { return }

        state = .downloading(progress: 0)

        // Start a background timer to poll download directory size for progress estimation.
        let dir = modelDirectory
        let expectedSize = estimatedDownloadBytes
        let progressTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let currentSize = (try? FileManager.default.allocatedSizeOfDirectory(at: dir)) ?? 0
                let fraction = min(Double(currentSize) / Double(expectedSize), 0.95) // Cap at 95% until confirmed
                await MainActor.run { [weak self, fraction] in
                    guard let self else { return }
                    if case .downloading = self.state {
                        self.state = .downloading(progress: fraction)
                    }
                }
            }
        }

        let task = Task {
            do {
                switch model {
                case .parakeet:
                    try await AsrModels.download(version: .v3)
                case .qwen:
                    try await Qwen3AsrModels.download()
                }
                guard !Task.isCancelled else { return }
                progressTask.cancel()
                state = .downloaded
                refreshModelSizeOnDisk()
            } catch {
                guard !Task.isCancelled else { return }
                progressTask.cancel()
                state = .error("Download failed: \(error.localizedDescription)")
            }
        }
        downloadTask = task
        await task.value
        progressTask.cancel()
        downloadTask = nil
    }

    /// Cancels an in-progress download and resets to not-downloaded state.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        // Clean up any partial files
        let dir = modelDirectory
        try? FileManager.default.removeItem(at: dir)
        state = .notDownloaded
        modelSizeOnDiskCached = ""
    }

    /// Loads the model into memory, returning when ready for transcription.
    func loadModel() async throws {
        if parakeetManager != nil || qwen3Manager != nil {
            state = .ready
            return
        }

        // If a load is already in-flight, await it instead of starting a duplicate.
        if let existing = loadTask {
            try await existing.value
            return
        }

        state = .loading

        let task = Task<Void, any Error> {
            switch model {
            case .parakeet:
                let dir = AsrModels.defaultCacheDirectory(for: .v3)
                let asrModels = try await AsrModels.load(from: dir, version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: asrModels)
                await MainActor.run { parakeetManager = manager }

            case .qwen:
                let dir = Qwen3AsrModels.defaultCacheDirectory()
                let manager = Qwen3AsrManager()
                try await manager.loadModels(from: dir)
                await MainActor.run { qwen3Manager = manager }
            }
        }
        loadTask = task

        do {
            try await task.value
            loadTask = nil
            state = .ready
            refreshModelSizeOnDisk()
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Transcribes audio from a file URL (used by Parakeet which requires a file).
    func transcribe(audioURL: URL) async throws -> String {
        switch model {
        case .parakeet:
            guard let manager = parakeetManager else {
                throw FluidAudioTranscriberError.modelNotLoaded
            }
            let result = try await manager.transcribe(audioURL, source: .system)
            return normalizeTranscript(result.text)

        case .qwen:
            // Prefer the in-memory path; file-based is kept as a fallback.
            guard let manager = qwen3Manager else {
                throw FluidAudioTranscriberError.modelNotLoaded
            }
            let audioConverter = AudioConverter()
            let audioSamples = try audioConverter.resampleAudioFile(audioURL)
            let text = try await manager.transcribe(audioSamples: audioSamples)
            return normalizeTranscript(text)
        }
    }

    /// Transcribes Qwen audio directly from in-memory float samples, avoiding temp file I/O.
    func transcribeInMemory(samples: [Float], sampleRate: Double) async throws -> String {
        guard model == .qwen else {
            throw FluidAudioTranscriberError.modelNotLoaded
        }
        guard let manager = qwen3Manager else {
            throw FluidAudioTranscriberError.modelNotLoaded
        }

        // Qwen expects 16kHz mono. Resample in-memory if needed.
        let targetRate: Double = 16000
        let audioSamples: [Float]
        if abs(sampleRate - targetRate) > 1.0 {
            audioSamples = Self.resampleForQwen(samples, from: sampleRate, to: targetRate)
        } else {
            audioSamples = samples
        }

        let text = try await manager.transcribe(audioSamples: audioSamples)
        return normalizeTranscript(text)
    }

    /// Resamples audio using linear interpolation via Accelerate.
    private nonisolated static func resampleForQwen(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = targetSampleRate / sourceSampleRate
        let outputLength = Int(Double(samples.count) * ratio)
        guard outputLength > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputLength)
        var control = (0..<outputLength).map { Float(Double($0) / ratio) }
        vDSP_vlint(samples, &control, 1, &output, 1, vDSP_Length(outputLength), vDSP_Length(samples.count))
        return output
    }

    /// Deletes the downloaded model files.
    func deleteModel() {
        parakeetManager = nil
        qwen3Manager = nil

        let dir = modelDirectory
        try? FileManager.default.removeItem(at: dir)
        state = .notDownloaded
        modelSizeOnDiskCached = ""
    }

    /// Releases the loaded runtime from memory while keeping files on disk.
    func unloadModelFromMemory() {
        loadTask?.cancel()
        loadTask = nil
        parakeetManager = nil
        qwen3Manager = nil
        switch state {
        case .ready, .loading:
            state = .downloaded
        default:
            break
        }
    }

    /// Size of the model on disk (cached, not computed on every view redraw).
    var modelSizeOnDisk: String { modelSizeOnDiskCached }

    /// Recalculates model size on disk and updates the cached value. (Fix #12)
    func refreshModelSizeOnDisk() {
        let dir = modelDirectory
        Task.detached(priority: .utility) {
            let sizeString: String
            if let size = try? FileManager.default.allocatedSizeOfDirectory(at: dir), size > 0 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = .file
                sizeString = formatter.string(fromByteCount: Int64(size))
            } else {
                sizeString = ""
            }
            await MainActor.run { [sizeString] in
                self.modelSizeOnDiskCached = sizeString
            }
        }
    }

    /// Whether a loaded runtime instance is available.
    var isLoaded: Bool {
        parakeetManager != nil || qwen3Manager != nil
    }

    /// Whether the downloaded model can currently be used for transcription.
    var isAvailableForTranscription: Bool {
        switch state {
        case .downloaded, .ready, .loading:
            return true
        default:
            return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = state {
            return true
        }
        return false
    }

    private func normalizeTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FluidAudioTranscriberError: LocalizedError {
    case modelNotLoaded
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "FluidAudio model is not loaded."
        case .emptyAudio:
            return "No audio was recorded."
        }
    }
}

// MARK: - FluidAudioTranscriber

/// Transcriber that uses FluidAudio (Parakeet or Qwen) for speech recognition.
/// Records audio into a buffer while the hotkey is held, writes to a temp WAV file,
/// then transcribes on release.
@MainActor
class FluidAudioTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    var onTranscriptionFinished: ((String) -> Void)?
    var selectedDeviceUID: String?

    let model: FluidAudioModel
    private let modelManager: FluidAudioModelManager

    private let microphoneCapture = MicrophoneCaptureSession()

    /// Thread-safe audio buffer protected by a serial queue.
    private let bufferQueue = DispatchQueue(label: "com.kaze.fluidaudio.audioBuffer")
    private var _audioBuffer: [Float] = []
    private var _inputSampleRate: Double = 16000
    private var transcriptionTask: Task<Void, Never>?

    /// Maximum recording duration in seconds.
    private static let maxRecordingSeconds: Double = 300 // 5 minutes
    private static let initialBufferCapacity: Int = 48000 * 60

    init(model: FluidAudioModel, modelManager: FluidAudioModelManager) {
        self.model = model
        self.modelManager = modelManager
    }

    deinit {
        transcriptionTask?.cancel()
        let capture = microphoneCapture
        Task { @MainActor in capture.stop() }
    }

    func requestPermissions() async -> Bool {
        let micStatus = await AVCaptureDevice.requestAccess(for: .audio)
        return micStatus
    }

    func startRecording() {
        guard !isRecording else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil

        // Reset buffer with pre-allocation
        bufferQueue.sync {
            _audioBuffer = []
            _audioBuffer.reserveCapacity(Self.initialBufferCapacity)
        }
        transcribedText = ""
        audioLevel = 0

        do {
            microphoneCapture.stop()
            microphoneCapture.onAudioChunk = { [weak self] chunk in
                guard let self else { return }

                let frameLength = chunk.monoSamples.count
                let maxSamples = Int(chunk.sampleRate * Self.maxRecordingSeconds)
                self.bufferQueue.sync {
                    self._inputSampleRate = chunk.sampleRate
                    guard self._audioBuffer.count < maxSamples else { return }
                    let remaining = maxSamples - self._audioBuffer.count
                    let samplesToAppend = min(frameLength, remaining)
                    self._audioBuffer.append(contentsOf: chunk.monoSamples.prefix(samplesToAppend))
                }

                let normalized = Self.normalizedAudioLevel(from: chunk.monoSamples)
                Task { @MainActor [weak self] in
                    self?.audioLevel = normalized
                }
            }

            try microphoneCapture.start(deviceUID: selectedDeviceUID)
            isRecording = true
        } catch {
            print("FluidAudioTranscriber: Failed to start recording: \(error)")
            microphoneCapture.stop()
            isRecording = false
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        microphoneCapture.stop()
        isRecording = false

        // Fix #1: Thread-safe buffer extraction
        let (capturedAudio, sampleRate) = bufferQueue.sync {
            let audio = _audioBuffer
            let rate = _inputSampleRate
            _audioBuffer = []
            return (audio, rate)
        }

        guard !capturedAudio.isEmpty else {
            onTranscriptionFinished?("")
            return
        }

        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.transcribeAudio(capturedAudio, sampleRate: sampleRate)
        }
    }

    private func transcribeAudio(_ samples: [Float], sampleRate: Double) async {
        guard !Task.isCancelled else { return }
        do {
            // Ensure model is loaded
            try await modelManager.loadModel()
            guard !Task.isCancelled else { return }

            let text: String
            if model == .qwen {
                // Qwen path: pass samples directly in-memory, avoiding temp file I/O.
                text = try await modelManager.transcribeInMemory(samples: samples, sampleRate: sampleRate)
            } else {
                // Parakeet path: requires a file URL.
                let tempURL = try writeWAVFile(samples: samples, sampleRate: sampleRate)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                text = try await modelManager.transcribe(audioURL: tempURL)
            }
            guard !Task.isCancelled else { return }

            transcribedText = text
            onTranscriptionFinished?(text)
        } catch {
            guard !Task.isCancelled else { return }
            print("FluidAudioTranscriber: Transcription failed: \(error)")
            onTranscriptionFinished?("")
        }
    }

    /// Writes raw float samples to a temporary WAV file.
    /// Uses memcpy instead of element-by-element copy (Fix #4).
    private func writeWAVFile(samples: [Float], sampleRate: Double) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("kaze_recording_\(UUID().uuidString).wav")

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw FluidAudioTranscriberError.emptyAudio
        }

        buffer.frameLength = frameCount
        // Fix #4: Use memcpy instead of element-by-element loop
        let channelData = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { src in
            channelData.update(from: src.baseAddress!, count: samples.count)
        }

        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        try file.write(from: buffer)

        return tempURL
    }

    private nonisolated static func normalizedAudioLevel(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        var rms: Float = 0
        for sample in samples {
            rms += sample * sample
        }
        rms = sqrt(rms / Float(samples.count))
        return min(rms * 20, 1.0)
    }
}
