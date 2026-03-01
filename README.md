# Kaze

Hold a global hotkey, speak, and the transcribed text is automatically pasted into whatever app you're using.


https://github.com/user-attachments/assets/8fde004a-e07a-45fc-ae3c-8f8a216873d3


## How it works

1. **Press your global hotkey** (default: `Option + Command`) to start recording.
2. **Speak** while Kaze captures audio and shows a floating waveform overlay.
3. **Stop recording** (release in Hold mode, or press again in Toggle mode).
4. **Kaze pastes the transcription** into the focused app while preserving your clipboard.

The app lives entirely in the menu bar with no Dock icon. The only UI during use is a minimal floating pill showing audio levels and live transcription.

## Features

- **Personal recommendation** -- use **Parakeet v3 (NVIDIA)** for the best overall results
- **4 on-device transcription engines**
  - **Direct Dictation** (`SFSpeechRecognizer`) -- zero setup
  - **Whisper (OpenAI)** via [WhisperKit](https://github.com/argmaxinc/WhisperKit) -- local model variants: Tiny, Base, Small, Large v3 Turbo
  - **Parakeet v3 (NVIDIA)** via [FluidAudio](https://github.com/FluidInference/FluidAudio) -- fast, high-accuracy English ASR
  - **Qwen3 ASR (Alibaba)** via FluidAudio -- multilingual ASR (30+ languages)
- **One-click model management in Settings** -- download/remove models, view readiness and model size on disk
- **Apple Intelligence enhancement** -- optionally post-process transcriptions with on-device Foundation Models to fix grammar, punctuation, and formatting (macOS 26.0+)
- **Flexible global hotkey system** -- configurable shortcut + two modes: **Hold to Talk** and **Press to Toggle**
- **Custom vocabulary/keywords** -- add names, abbreviations, and domain terms to improve recognition biasing
- **Transcription history** -- persistent local history (latest 50 entries), with engine labels and one-click copy
- **Animated waveform overlay** -- floating non-activating panel with real-time audio level bars and scrolling transcription text
- **Processing state UI** -- overlay switches to a processing animation while post-recording model inference/enhancement runs
- **Clipboard-safe auto-paste** -- saves and restores your clipboard contents around each paste
- **Graceful fallback** -- if a selected downloadable model is unavailable, Kaze falls back to Direct Dictation

## Tech stack

- **SwiftUI** + **AppKit** -- SwiftUI for the settings and overlay views, AppKit for the menu bar, floating panel, clipboard, and simulated key events
- **Speech framework** -- `SFSpeechRecognizer` for real-time streaming dictation
- **WhisperKit** -- local OpenAI Whisper transcription
- **FluidAudio** -- local Parakeet v3 and Qwen3 ASR CoreML runtimes
- **Foundation Models** -- Apple Intelligence on-device LLM for text enhancement
- **CGEvent** -- global hotkey detection via a low-level event tap
- **Combine** -- reactive state bridging between transcription engines and the UI

## Requirements

- macOS 26.0+
- Xcode 26+
- Accessibility permission (for global hotkey)
- Microphone permission
- Speech Recognition permission (used by Direct Dictation)

## Building

Open `Kaze.xcodeproj` in Xcode and build. Dependencies (`WhisperKit` + `FluidAudio`) are resolved automatically via Swift Package Manager.

## License

MIT
