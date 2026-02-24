import SwiftUI

struct ContentView: View {
    @AppStorage(AppPreferenceKey.transcriptionEngine) private var engineRaw = TranscriptionEngine.dictation.rawValue
    @AppStorage(AppPreferenceKey.enhancementMode) private var enhancementModeRaw = EnhancementMode.off.rawValue
    @AppStorage(AppPreferenceKey.enhancementSystemPrompt) private var systemPrompt = AppPreferenceKey.defaultEnhancementPrompt

    @ObservedObject var whisperModelManager: WhisperModelManager

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw) ?? .dictation
    }

    private var appleIntelligenceAvailable: Bool {
        if #available(macOS 26.0, *) {
            return TextEnhancer.isAvailable
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image("kaze-icon")
                    .resizable()
                    .frame(width: 24, height: 24)
                Text("Kaze Settings")
                    .font(.title2.weight(.semibold))
            }
            // MARK: - Transcription Engine
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription")
                        .font(.headline)

                    Picker("Engine", selection: $engineRaw) {
                        ForEach(TranscriptionEngine.allCases) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)

                    Text(selectedEngine.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Whisper model management (only shown when Whisper is selected)
                    if selectedEngine == .whisper {
                        whisperModelSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            // MARK: - Text Enhancement
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Text Enhancement")
                        .font(.headline)

                    Picker("Enhancement", selection: $enhancementModeRaw) {
                        Text(EnhancementMode.off.title).tag(EnhancementMode.off.rawValue)
                        Text(EnhancementMode.appleIntelligence.title)
                            .tag(EnhancementMode.appleIntelligence.rawValue)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)

                    if !appleIntelligenceAvailable {
                        Text("Apple Intelligence is not available on this Mac right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if enhancementModeRaw == EnhancementMode.appleIntelligence.rawValue {
                        Divider()

                        Text("System Prompt")
                            .font(.subheadline.weight(.medium))

                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 100)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )

                        HStack {
                            Text("Customise how Apple Intelligence enhances your transcriptions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Reset to Default") {
                                systemPrompt = AppPreferenceKey.defaultEnhancementPrompt
                            }
                            .controlSize(.small)
                            .disabled(systemPrompt == AppPreferenceKey.defaultEnhancementPrompt)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Whisper Model Section

    @ViewBuilder
    private var whisperModelSection: some View {
        Divider()

        switch whisperModelManager.state {
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                Text("Whisper model needs to be downloaded (~75 MB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Download Model") {
                    Task {
                        await whisperModelManager.downloadModel()
                    }
                }
                .controlSize(.small)
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(maxWidth: 200)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text("Downloading Whisper model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .downloaded:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Model downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !whisperModelManager.modelSizeOnDisk.isEmpty {
                        Text("(\(whisperModelManager.modelSizeOnDisk))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Button("Remove Model", role: .destructive) {
                    whisperModelManager.deleteModel()
                    // Switch back to dictation if model is removed
                    engineRaw = TranscriptionEngine.dictation.rawValue
                }
                .controlSize(.small)
            }

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Model ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !whisperModelManager.modelSizeOnDisk.isEmpty {
                    Text("(\(whisperModelManager.modelSizeOnDisk))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Retry Download") {
                    whisperModelManager.deleteModel()
                    Task {
                        await whisperModelManager.downloadModel()
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
