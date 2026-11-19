# Haru4iOS

Haru-4B を iPad / iPhone 上でローカル実行するための iOS プロジェクトです。

> **Status: iPhoneOS arm64 app integration implemented; physical-device validation pending**
> SwiftUI アプリ、Haru Dialogue C API、マイク・スピーカー経路、キャラクタープロファイル、参照音声からのカスタムボイス登録を実装しています。GitHub Actions のビルド成功は、実機でのモデルロード・音声変換・全二重対話の成功を意味しません。

## Goal

- Haru-4B のネイティブな full-duplex 音声対話を iOS 上で実行する
- 音声入力と音声出力を同時に扱い、発話中の割り込みにも対応する
- 推論・音声処理を端末内で完結させる（クラウド推論なし）
- 第一ターゲットは **M2 iPad Air / 8 GB unified memory**
- Swift のアプリ層と、Metal 対応 C/C++ 推論ランタイムを分離する

## Non-goals

- ASR → LLM → TTS をつないだ疑似 full-duplex への置き換え
- 音声のクラウド送信を前提とする設計
- モデル重みやユーザーの音声データを Git に登録すること

## Architecture

```text
SwiftUI app
  ├─ Model installer / character profile store
  ├─ Audio file importer (AVFoundation decode → mono 24 kHz PCM WAV)
  ├─ HaruEngine (serial inference queue)
  │    └─ Objective-C++ C ABI bridge
  │         └─ speech.cpp Haru dialogue API
  │              └─ ggml / Metal
  └─ AVAudioEngine + bounded input/output queues

Microphone ──> bounded audio input queue ──> Haru dialogue session
Speaker   <── bounded audio output queue <── Haru generated audio
                         └──────────────> text events / UI
```

The app automatically downloads the speech.cpp-compatible Haru-4B Q4_K GGUF on first launch, verifies its exact byte size and SHA-256, stores it in Application Support, and loads it before showing the dialogue test screen. The app also imports audio formats that the device's AVFoundation decoder can read (for example WAV, M4A/AAC, MP3, AIFF and CAF), converts the selected reference to mono 24 kHz PCM WAV, and creates a model-compatible `.voice.gguf` locally. The voice file and Haru character-card fields are stored together as a reusable profile in Application Support. The original recording is not retained by the profile.

## Engineering principles

1. Preserve Haru's native streaming dialogue semantics. Do not silently turn the runtime into a turn-based ASR/LLM/TTS pipeline.
2. Keep real-time audio callbacks small and non-blocking. Model inference must not run on the audio render thread.
3. Use bounded queues and explicit back-pressure; avoid unbounded audio buffering.
4. Measure app-wide physical memory footprint, model load peak, first-response latency, steady-state latency, and thermal behavior on a physical iPad.
5. Treat model file size and runtime memory as separate quantities. An 8 GB device needs measured headroom for iPadOS, Metal buffers, caches, codec state, and audio I/O.
6. Never label a feature complete based only on a successful compile. Record device, OS, model quantization, test duration, and result.

## Initial target

| Item | Target |
|---|---|
| Device | iPad Air (M2, 8 GB) |
| Runtime | iOS / iPadOS native app |
| Inference | speech.cpp Haru backend + ggml Metal |
| Interaction | Native full-duplex streaming |
| Network | Required once to download the model; inference is local afterward |
| UI | SwiftUI |

## Milestones

- [x] M0 — Verify upstream Haru and speech.cpp APIs, revisions, licenses, and iOS constraints
- [x] M1 — Build a minimal iOS arm64 Metal runtime artifact (GitHub Actions build passed)
- [ ] M2 — Load a compatible Haru model and run a non-audio smoke test on device
- [x] M3 — Connect the native dialogue API through a Swift wrapper (build validation pending)
- [x] M4 — Implement real-time microphone input and speaker output (physical-device validation pending)
- [x] M4a — Import reference audio, create voice files, and save voice + character-card profiles
- [ ] M5 — Verify simultaneous listening/speaking and interruption behavior
- [ ] M6 — Measure memory, latency, stability, and thermal behavior on M2 iPad Air
- [ ] M7 — Package a reproducible Xcode project, tests, and setup documentation

## Build

### Native runtime

```sh
bash Scripts/build-ios-runtime.sh
```

The script pins speech.cpp commit `8d18924cd238b87c0297df112f7ff40783a6414f` (0.11.0 / C API 4.2), builds iPhoneOS arm64, and packages `SpeechCpp.xcframework`.

The first GitHub Actions runtime build succeeded, including both platform slices and Artifact upload:

- [Successful runtime build](https://github.com/yanyantukebo1224/Haru4iOS/actions/runs/44427011601)
- [Runtime build workflow](.github/workflows/build-ios-runtime.yml)

The uploaded Artifact is named `Haru4iOS-SpeechCpp-0.11.0`. It contains an outer Actions ZIP with `SpeechCpp.xcframework.zip` and `SHA256SUMS`. Artifacts expire after 14 days; rebuild from the pinned source when needed.

### App project

The Xcode project is generated with XcodeGen. CI builds the iPhoneOS arm64 runtime and app:

```sh
brew install cmake ninja xcodegen
bash Scripts/build-ios-runtime.sh
mkdir -p Frameworks
cp -R Artifacts/SpeechCpp.xcframework Frameworks/SpeechCpp.xcframework
xcodegen generate
xcodebuild -project Haru4iOS.xcodeproj -scheme Haru4iOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions also performs this sequence in [the app build workflow](.github/workflows/build-ios-app.yml). A successful Simulator compile is not proof of model loading or real-time performance on an iPad. The CI artifact is deliberately named `Haru4iOS-unsigned-for-signing.ipa`: it is a correctly structured, validated IPA container, but it is **not installable until it is signed with a provisioning profile and signing identity valid for the target device**. CI cannot manufacture those credentials. The previous artifact was also unsigned; the inability to install it was not a ZIP-layout issue.

## Current app scope

- Install the pinned Haru-4B Q4_K GGUF from the configured model source.
- Load the model through speech.cpp with the automatic device selection.
- Edit and save character-card fields: name, persona, gender, backchannel, other name, relationship and situation.
- Import reference audio accepted by AVFoundation, convert it to mono 24 kHz PCM WAV, create a `.voice.gguf`, and register it with the loaded model.
- Save the custom voice file and character-card settings together in reusable profiles; register a saved voice lazily when its profile is selected after relaunch.
- Start a Haru native dialogue session with the selected profile and receive frame PCM/text callbacks.
- Physical-device validation of audio-format coverage, voice generation, memory use, latency, route changes, interruption handling and full-duplex stability remains outstanding.

Do not assume every GGUF quantization fits the iPad's available memory. Begin with short dialogue limits and measure physical footprint on the actual device.

## Repository policy

- Do not commit model weights, recordings, signing assets, or generated build products.
- Pin upstream source revisions and record local patches.
- Keep a clear distinction between **planned**, **implemented**, **built**, and **verified on device**.
- Add automated tests alongside each implementation milestone.

## Technical notes

- [iOS runtime design](docs/IOS_RUNTIME_DESIGN.md) — dialogue API semantics, audio-threading design, memory constraints, and implementation sequence.

## References

- [Haru](https://github.com/higurashi-ai/Haru)
- [speech.cpp](https://github.com/nyosegawa/speech.cpp)
- [Irodori TTS for iPhone](https://github.com/Corvelis/irodori-tts-iphone) — reference for iOS integration patterns, not a Haru runtime.
