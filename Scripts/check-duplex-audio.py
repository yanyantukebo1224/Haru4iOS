#!/usr/bin/env python3
"""Static regression checks for the iOS full-duplex audio pipeline."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
engine = (root / "Sources/Haru4iOS/HaruEngine.swift").read_text()
ui = (root / "Sources/Haru4iOS/ContentView.swift").read_text()

checks = {
    "startup audio is discarded after dialogue_start": "let discarded = self.audioIO.discardPendingInput()" in engine,
    "speak_first matches upstream CLI default": "voice, 30.0, 0, haruFrameCallback" in engine,
    "input pump drains accumulated audio": "let pcm = self.audioIO.takeInput()" in engine,
    "input queue latency is bounded": "queuedMilliseconds + outputQueuedMilliseconds > 1_000" in engine,
    "input overflow is surfaced": "dropped > 0" in engine and "overflow" in engine,
    "output scheduling is serialized": "self.outputQueue.async" in engine,
    "frame text is concatenated": "self.lastText += message" in engine,
    "PCM level is measured": "rms = pcm.isEmpty ? 0" in engine and "peak=%.4f" in engine,
    "input and output diagnostics are visible": "engine.inputDiagnostics" in ui and "engine.outputDiagnostics" in ui,
    "startup button is disabled while starting": "engine.isDialogueStarting" in ui,
}
failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + name)
if failed:
    raise SystemExit(1)
print(f"All {len(checks)} duplex pipeline checks passed.")
