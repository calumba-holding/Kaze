import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class AppleSpeechModelManager: ObservableObject {
    enum ModelState: Equatable {
        case checking
        case notDownloaded
        case downloading(progress: Double)
        case ready
        case unsupported
        case error(String)
    }

    @Published private(set) var state: ModelState = .checking

    private var downloadTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var downloadGeneration: UUID?
    private var statusGeneration = UUID()

    var isReady: Bool {
        state == .ready
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    init() {
        Task { await refreshStatus() }
    }

    deinit {
        downloadTask?.cancel()
        progressTask?.cancel()
    }

    func refreshStatus() async {
        guard downloadTask == nil else { return }
        let generation = UUID()
        statusGeneration = generation
        state = .checking

        guard Speech.SpeechTranscriber.isAvailable,
              let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            guard statusGeneration == generation, downloadTask == nil else { return }
            state = .unsupported
            return
        }

        let module = Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [module])
        guard statusGeneration == generation, downloadTask == nil else { return }
        switch status {
        case .installed:
            state = .ready
        case .unsupported:
            state = .unsupported
        case .supported:
            state = .notDownloaded
        case .downloading:
            state = .notDownloaded
        @unknown default:
            state = .notDownloaded
        }
    }

    func downloadModel() async {
        guard downloadTask == nil else { return }

        let generation = UUID()
        statusGeneration = generation
        downloadGeneration = generation

        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.downloadGeneration == generation {
                    self.progressTask?.cancel()
                    self.progressTask = nil
                    self.downloadTask = nil
                    self.downloadGeneration = nil
                }
            }

            guard Speech.SpeechTranscriber.isAvailable,
                  let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
                self.state = .unsupported
                return
            }

            let module = Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            do {
                guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
                    self.state = .ready
                    return
                }

                self.state = .downloading(progress: 0)
                self.progressTask = Task { [weak self, progress = request.progress] in
                    while !Task.isCancelled {
                        self?.state = .downloading(progress: progress.fractionCompleted)
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                }

                try await request.downloadAndInstall()
                guard !Task.isCancelled else { return }
                guard self.downloadGeneration == generation else { return }
                self.state = .ready
            } catch is CancellationError {
                guard self.downloadGeneration == generation else { return }
                await self.refreshStatus()
            } catch {
                guard self.downloadGeneration == generation else { return }
                self.state = .error(error.localizedDescription)
            }
        }

        await downloadTask?.value
    }

    func cancelDownload() {
        statusGeneration = UUID()
        downloadGeneration = nil
        downloadTask?.cancel()
        downloadTask = nil
        progressTask?.cancel()
        progressTask = nil
        Task { await refreshStatus() }
    }

    func makeTranscriber() async throws -> Speech.SpeechTranscriber {
        guard let locale = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw AppleSpeechError.unsupportedLocale
        }
        let module = Speech.SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            state = .notDownloaded
            throw AppleSpeechError.modelNotInstalled
        }
        state = .ready
        return module
    }
}

private enum AppleSpeechError: LocalizedError {
    case unsupportedLocale
    case modelNotInstalled
    case unavailableAudioFormat
    case audioConversionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return "Apple Speech does not support the current language."
        case .modelNotInstalled:
            return "The Apple Speech model is not installed."
        case .unavailableAudioFormat:
            return "Apple Speech could not select a compatible audio format."
        case .audioConversionFailed:
            return "Kaze could not convert microphone audio for Apple Speech."
        }
    }
}

@MainActor
final class SpeechTranscriber: ObservableObject, TranscriberProtocol {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0
    @Published var transcribedText = ""
    @Published var isEnhancing = false

    var onTranscriptionFinished: ((String) -> Void)?
    var selectedDeviceUID: String?

    private let modelManager: AppleSpeechModelManager
    private let microphoneCapture = MicrophoneCaptureSession()

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var finalizationTask: Task<Void, Never>?
    private var finalizedTranscript = ""
    private var volatileTranscript = ""
    private var hasDeliveredFinalResult = false
    private var stopRequested = false
    private var analyzerStarted = false
    private var inputPipeline: AppleSpeechInputPipeline?

    init(modelManager: AppleSpeechModelManager) {
        self.modelManager = modelManager
    }

    deinit {
        setupTask?.cancel()
        resultsTask?.cancel()
        finalizationTask?.cancel()
        let capture = microphoneCapture
        Task { @MainActor in capture.stop() }
    }

    func requestPermissions() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startRecording() {
        guard !isRecording else { return }
        guard modelManager.isReady else {
            print("Apple Speech model is not ready")
            return
        }

        cleanupSessionState()
        transcribedText = ""
        finalizedTranscript = ""
        volatileTranscript = ""
        audioLevel = 0
        hasDeliveredFinalResult = false
        stopRequested = false
        analyzerStarted = false
        isRecording = true

        let pipeline = AppleSpeechInputPipeline()
        inputPipeline = pipeline
        microphoneCapture.stop()
        microphoneCapture.onAudioChunk = { [weak self, pipeline] chunk in
            pipeline.consume(samples: chunk.monoSamples, sampleRate: chunk.sampleRate)

            let normalized = Self.normalizedAudioLevel(from: chunk.monoSamples)
            Task { @MainActor [weak self] in
                self?.audioLevel = normalized
            }
        }

        do {
            try microphoneCapture.start(deviceUID: selectedDeviceUID)
        } catch {
            print("Apple Speech microphone capture failed: \(error)")
            isRecording = false
            finishRecognition(with: "")
            return
        }

        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startSpeechAnalysis()
            } catch is CancellationError {
            } catch {
                print("Apple Speech failed to start: \(error)")
                self.microphoneCapture.stop()
                self.isRecording = false
                self.finishRecognition(with: self.transcribedText)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        stopRequested = true
        microphoneCapture.stop()
        isRecording = false
        inputPipeline?.finish()

        guard analyzerStarted, let analyzer else { return }
        finalize(analyzer)
    }

    private func finalize(_ analyzer: SpeechAnalyzer) {
        guard finalizationTask == nil else { return }
        finalizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await self.resultsTask?.value
            } catch is CancellationError {
            } catch {
                print("Apple Speech finalization failed: \(error)")
            }
            self.finishRecognition(with: self.currentTranscript)
        }
    }

    private func startSpeechAnalysis() async throws {
        let module = try await modelManager.makeTranscriber()
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw AppleSpeechError.unavailableAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        let (inputSequence, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedTranscript = Self.appending(text, to: self.finalizedTranscript)
                        self.volatileTranscript = ""
                    } else {
                        self.volatileTranscript = text
                    }
                    self.transcribedText = self.currentTranscript
                }
            } catch is CancellationError {
            } catch {
                print("Apple Speech results failed: \(error)")
            }
        }

        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: inputSequence)
        analyzerStarted = true

        if stopRequested {
            inputPipeline?.attach(analyzerFormat: analyzerFormat, continuation: continuation)
            inputPipeline?.finish()
            finalize(analyzer)
            return
        }

        inputPipeline?.attach(analyzerFormat: analyzerFormat, continuation: continuation)
    }

    private var currentTranscript: String {
        Self.appending(volatileTranscript, to: finalizedTranscript)
    }

    private func cleanupSessionState() {
        setupTask?.cancel()
        setupTask = nil
        resultsTask?.cancel()
        resultsTask = nil
        finalizationTask?.cancel()
        finalizationTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        analyzerStarted = false
        inputPipeline = nil
    }

    private func finishRecognition(with text: String) {
        guard !hasDeliveredFinalResult else { return }
        hasDeliveredFinalResult = true
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupSessionState()
        onTranscriptionFinished?(finalText)
    }

    private nonisolated static func appending(_ text: String, to existing: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return existing }
        guard !existing.isEmpty else { return text }
        return existing + " " + text
    }

    fileprivate nonisolated static func makePCMBuffer(samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard !samples.isEmpty,
              let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
              ),
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            throw AppleSpeechError.audioConversionFailed
        }

        sourceBuffer.frameLength = sourceBuffer.frameCapacity
        samples.withUnsafeBufferPointer { source in
            sourceBuffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }

        return sourceBuffer
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

private final class AppleSpeechInputPipeline: @unchecked Sendable {
    private struct PendingChunk {
        let samples: [Float]
        let sampleRate: Double
    }

    private let lock = NSLock()
    private var pendingChunks: [PendingChunk] = []
    private var pendingDuration: TimeInterval = 0
    private var converter: AppleSpeechAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var isFinished = false

    func consume(samples: [Float], sampleRate: Double) {
        lock.withLock {
            guard !isFinished else { return }
            guard let converter, let continuation else {
                pendingChunks.append(PendingChunk(samples: samples, sampleRate: sampleRate))
                pendingDuration += Double(samples.count) / sampleRate
                while pendingDuration > 10, !pendingChunks.isEmpty {
                    let removed = pendingChunks.removeFirst()
                    pendingDuration -= Double(removed.samples.count) / removed.sampleRate
                }
                return
            }
            yield(samples: samples, sampleRate: sampleRate, converter: converter, continuation: continuation)
        }
    }

    func attach(analyzerFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.withLock {
            guard self.continuation == nil else { return }
            let converter = AppleSpeechAudioConverter(analyzerFormat: analyzerFormat)
            self.converter = converter
            self.continuation = continuation
            for chunk in pendingChunks {
                yield(samples: chunk.samples, sampleRate: chunk.sampleRate, converter: converter, continuation: continuation)
            }
            pendingChunks.removeAll()
            pendingDuration = 0
            if isFinished {
                flushAndFinish(converter: converter, continuation: continuation)
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !isFinished else { return }
            isFinished = true
            if let converter, let continuation {
                flushAndFinish(converter: converter, continuation: continuation)
                pendingChunks.removeAll()
                pendingDuration = 0
            }
        }
    }

    private func flushAndFinish(
        converter: AppleSpeechAudioConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        do {
            for input in try converter.flush() {
                continuation.yield(input)
            }
        } catch {
            print("Apple Speech audio flush failed: \(error)")
        }
        continuation.finish()
    }

    private func yield(
        samples: [Float],
        sampleRate: Double,
        converter: AppleSpeechAudioConverter,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        do {
            for input in try converter.convert(samples: samples, sampleRate: sampleRate) {
                continuation.yield(input)
            }
        } catch {
            print("Apple Speech audio conversion failed: \(error)")
        }
    }
}

private final class AppleSpeechAudioConverter: @unchecked Sendable {
    private let analyzerFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    init(analyzerFormat: AVAudioFormat) {
        self.analyzerFormat = analyzerFormat
    }

    func convert(samples: [Float], sampleRate: Double) throws -> [AnalyzerInput] {
        let sourceBuffer = try SpeechTranscriber.makePCMBuffer(samples: samples, sampleRate: sampleRate)
        if sourceBuffer.format == analyzerFormat {
            return [AnalyzerInput(buffer: sourceBuffer)]
        }

        if sourceFormat != sourceBuffer.format {
            sourceFormat = sourceBuffer.format
            converter = AVAudioConverter(from: sourceBuffer.format, to: analyzerFormat)
        }
        guard let converter else { throw AppleSpeechError.audioConversionFailed }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * analyzerFormat.sampleRate / sourceBuffer.format.sampleRate)
        ) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outputCapacity) else {
            throw AppleSpeechError.audioConversionFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error, conversionError == nil else {
            throw conversionError ?? AppleSpeechError.audioConversionFailed
        }
        guard outputBuffer.frameLength > 0 else { return [] }
        return [AnalyzerInput(buffer: outputBuffer)]
    }

    func flush() throws -> [AnalyzerInput] {
        guard let converter else { return [] }
        var inputs: [AnalyzerInput] = []

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: 1024) else {
                throw AppleSpeechError.audioConversionFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let conversionError { throw conversionError }
            if outputBuffer.frameLength > 0 {
                inputs.append(AnalyzerInput(buffer: outputBuffer))
            }
            if status == .endOfStream || outputBuffer.frameLength == 0 { break }
        }

        return inputs
    }
}
