# iOS runtime design

Status: speech.cpp 0.11.0 iPhoneOS arm64 and iOS Simulator arm64 XCFramework build has succeeded in GitHub Actions. A first Objective-C++ bridge, Swift coordinator, and SwiftUI smoke-test screen are committed. Haru GGUF loading and dialogue execution on a physical iPad are not yet verified.

## Confirmed upstream API

The current speech.cpp source reports:

- speech.cpp release: 0.11.0
- C API: 4.2
- dialogue API: `speech_dialogue_start`, `speech_dialogue_push`, `speech_dialogue_end`, `speech_dialogue_free`
- Haru task: `SPEECH_TASK_DIALOGUE`
- Haru audio: mono, 24 kHz, 3,200 samples per frame (about 133.3 ms)

The dialogue API is the correct integration surface. It is not a turn-based transcription or synthesis API.

### API behavior that affects the iOS design

1. `speech_dialogue_start()` starts the prompt and invokes the first output-frame callback before returning.
2. `speech_dialogue_push()` accepts mono float samples at the input sample rate supplied to start. It resamples internally to the model rate.
3. For each complete model frame that arrives, `push()` computes and delivers the corresponding output frame before returning.
4. The output callback runs on the same thread that called `start()` or `push()`.
5. The callback's sample pointer and UTF-8 text pointer are valid only during that callback. Copy the samples/text before returning if they must outlive it.
6. The callback must not call back into the same model. Returning nonzero stops the dialogue.
7. A dialogue is used by one thread at a time. The model is held while a dialogue call computes.
8. `speech_dialogue_end()` drops any input samples short of a complete frame.

These semantics mean that inference must **not** run on AVAudioEngine's real-time render callback. A dedicated serial inference worker should call the dialogue API.

## Proposed data flow

```text
AVAudioEngine input tap
    │  copy/convert mic samples; never run inference here
    ▼
bounded input ring buffer
    │
    ▼
serial Haru worker
    ├── speech_dialogue_start / speech_dialogue_push
    │       │
    │       └── frame callback: copy 3,200 float samples + text event
    ▼
bounded output ring buffer ──> AVAudioEngine player node
                                  │
                                  ▼
                                speaker

Frame text events ──> MainActor / SwiftUI
```

The worker is the only thread that calls the dialogue object. Audio input and output callbacks only move samples through bounded buffers. The output callback must not block, allocate large objects, or update SwiftUI.

### Buffer and overload policy

- Use preallocated, bounded single-producer/single-consumer buffers where possible.
- Record input overrun, output underrun, worker frame duration, and queued audio duration.
- Do not silently grow queues without limit.
- If the worker falls behind persistently, surface a clear "inference cannot keep up" state rather than hiding dropped audio.
- Copy callback output immediately; never retain the C pointer.
- Keep text delivery separate from PCM delivery.

### Audio formats

Haru emits 24 kHz mono float audio in 3,200-sample frames. The microphone route's actual sample rate must be read after configuring AVAudioSession; pass that exact rate to `speech_dialogue_start()`. speech.cpp handles resampling to the model's sample rate. Convert the 24 kHz model output to the active playback format outside the real-time callback, or use an audio graph conversion node.

Use headphones for initial tests. Speaker playback can feed the model's own voice back into the microphone.

## Model loading and memory

The upstream Haru guide reports the following M5 Metal figures. They are reference data, **not M2 iPad measurements**:

| Quantization | File size | M5 peak memory |
|---|---:|---:|
| F16 | 10.56 GB | 10.84 GB |
| Q8_0 | 6.62 GB | 6.90 GB |
| Q6_K | 5.61 GB | 5.89 GB |
| Q5_K | 5.05 GB | 5.33 GB |
| Q4_K | 4.52 GB | 4.80 GB |

The KV cache also grows with `max_seconds`: the upstream guide reports about 0.3 GB for 10 minutes and 1.7 GB for 60 minutes on its 8 GB GPU example. iPad unified memory is shared with the OS, display, app, Metal allocations, codec state, and audio buffers.

Initial M2 experiments should therefore use a short `max_seconds`, measure physical footprint during load and dialogue, and test quantizations separately. Do not assume that a GGUF whose file fits in storage will fit in RAM. Q4_K is a possible low-memory smoke-test candidate, not a quality recommendation: the upstream guide reports text degradation in a speak-first/no-card case. Q8_0 and above may be too memory-heavy for an 8 GB iPad; this must be measured.

## iOS build strategy

Use the Irodori iPhone project as a **packaging reference only**:

- Build speech.cpp for iPhoneOS arm64 and (optionally) iOS Simulator arm64.
- Embed the Metal library in the framework.
- Package the runtime as an XCFramework.
- Expose the C API through a small Objective-C++ / C++ bridge and a Swift Package.
- Keep model weights outside the repository; download/import them into app storage and verify hashes.

Do not reuse Irodori's prebuilt runtime: its documented build pins speech.cpp 0.8.10, while Haru's dialogue API is present in the current 0.11.0 / C API 4.2 source. Rebuild from a Haru-capable revision.

The pinned speech.cpp source and its recursive submodules built successfully in GitHub Actions with the current iOS Metal flags and iOS 17 deployment target. The resulting XCFramework contains arm64 device and arm64 simulator slices. This confirms compilation and packaging, not runtime compatibility on an iPad.

## Implementation sequence

1. [x] Build a minimal iOS arm64 speech.cpp framework with Haru enabled and Metal embedded.
2. [x] Add the Objective-C++ C ABI bridge and Swift coordinator for model/dialogue lifetime.
3. [ ] Compile the generated Xcode app in GitHub Actions and fix any Swift/Clang integration issues.
4. [ ] Load the selected GGUF on device and report peak app physical footprint.
5. [ ] Test dialogue start and replay a known audio fixture through push; verify frame count, 24 kHz output, and callback text.
6. [ ] Connect AVAudioEngine input/output using bounded buffers.
7. [ ] Test simultaneous capture/playback, interruptions, route changes, background/foreground transitions, and sustained sessions.
8. [ ] Benchmark on the physical M2 iPad Air: p50/p95/p99 frame time, real-time factor, input queue delay, output underruns, RAM, and thermal state.

## Source references

- [speech.cpp VERSION](https://github.com/nyosegawa/speech.cpp/blob/main/VERSION)
- [C API header](https://github.com/nyosegawa/speech.cpp/blob/main/include/speech.h)
- [Dialogue API implementation](https://github.com/nyosegawa/speech.cpp/blob/main/src/api/dialogue.cpp)
- [Haru model guide](https://github.com/nyosegawa/speech.cpp/blob/main/docs/models/haru.md)
- [Irodori iOS runtime build script](https://github.com/Corvelis/irodori-tts-iphone/blob/main/Packages/IrodoriSpeechCpp/Scripts/build-runtime.sh)
