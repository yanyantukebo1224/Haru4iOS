# Haru4iOS

Haru-4B を iPad / iPhone 上でローカル実行するための iOS プロジェクトです。

> **Status: Planning / bootstrap**
> まだ実機での Haru-4B 動作を確認した段階ではありません。ビルド・推論・全二重音声入出力は、検証結果に応じて段階的に完了扱いにします。

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

## Proposed architecture

```text
SwiftUI app
  ├─ Audio I/O (AVAudioEngine / AVAudioSession)
  ├─ Dialogue coordinator (lifecycle, interruption, state)
  ├─ Swift Haru API
  │    └─ C ABI bridge
  │         └─ speech.cpp Haru runtime
  │              └─ ggml / Metal
  └─ Model store (download/import, size + SHA-256 validation)

Microphone ──> bounded audio input queue ──> Haru dialogue session
Speaker   <── bounded audio output queue <── Haru generated audio
                         └──────────────> text events / UI
```

This is a proposed integration boundary, not a claim that every component is already implemented or verified on iOS.

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
| Inference | speech.cpp Haru backend + ggml Metal, subject to iOS validation |
| Interaction | Native full-duplex streaming |
| Network | Not required for inference; model acquisition may be optional |
| UI | SwiftUI |

## Milestones

- [ ] M0 — Verify upstream Haru and speech.cpp APIs, revisions, licenses, and iOS constraints
- [ ] M1 — Build a minimal iOS arm64 Metal runtime artifact
- [ ] M2 — Load a compatible Haru model and run a non-audio smoke test
- [ ] M3 — Connect the native dialogue API through a Swift wrapper
- [ ] M4 — Implement real-time microphone input and speaker output
- [ ] M5 — Verify simultaneous listening/speaking and interruption behavior
- [ ] M6 — Measure memory, latency, stability, and thermal behavior on M2 iPad Air
- [ ] M7 — Package a reproducible Xcode project, tests, and setup documentation

## Repository policy

- Do not commit model weights, recordings, signing assets, or generated build products.
- Pin upstream source revisions and record local patches.
- Keep a clear distinction between **planned**, **implemented**, **built**, and **verified on device**.
- Add automated tests alongside each implementation milestone.

## References

- [Haru](https://github.com/higurashi-ai/Haru)
- [speech.cpp](https://github.com/nyosegawa/speech.cpp)
- [Irodori TTS for iPhone](https://github.com/Corvelis/irodori-tts-iphone) — reference for the iOS Swift Package / XCFramework integration pattern; it is not a Haru runtime.
