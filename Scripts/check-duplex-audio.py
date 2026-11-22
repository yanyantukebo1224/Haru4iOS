#!/usr/bin/env python3
"""Static regression checks for the device audio path and simulator mini-diagnostics."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
engine = (root / "Sources/Haru4iOS/HaruEngine.swift").read_text()
ui = (root / "Sources/Haru4iOS/ContentView.swift").read_text()
sim = (root / "Sources/Haru4iOS/SimulatorDiagnostics.swift").read_text()
installer = (root / "Sources/Haru4iOS/HaruModelInstaller.swift").read_text()

checks = {
    "startup audio is discarded after dialogue_start": "let discarded = self.audioIO.discardPendingInput()" in engine,
    "speak_first matches upstream CLI default and 1-hour session limit": "voice, 3600.0, 0, haruFrameCallback" in engine,
    "input pump drains accumulated audio": "let pcm = self.audioIO.takeInput()" in engine,
    "temporary backlog does not terminate dialogue": "Temporary input/output backlog" in engine and "queuedMilliseconds + outputQueuedMilliseconds > 1_000" not in engine,
    "input overflow is surfaced without forced stop": "droppedMilliseconds" in engine and "欠落 %.0f ms" in engine,
    "output scheduling is serialized": "outputQueue.async { [audioIO]" in engine,
    "frame text is concatenated": "self.lastText += message" in engine,
    "PCM level is measured": "rms = pcm.isEmpty ? 0" in engine and "peak=%.4f" in engine,
    "main conversation view excludes low-level diagnostics": "engine.inputDiagnostics" not in ui and "engine.outputDiagnostics" not in ui,
    "start button is disabled while starting": "engine.isDialogueStarting" in ui,
    "settings are separated into navigation hierarchy": "AppSettingsView" in ui and "CharacterSettingsView" in ui and "VoiceSettingsView" in ui,
    "simulator mini-diagnostic has deterministic PCM frame": "3_200" in sim and "24_000" in sim,
    "simulator mini-diagnostic checks RMS, peak, callback and state": all(x in sim for x in ["RMS", "ピーク計算", "コールバック文字列", "状態遷移"]),
    "simulator never downloads the 4.5GB model": "#if targetEnvironment(simulator)" in installer and "Never download" in installer,
    "simulator diagnostics are selected only in simulator builds": "#if targetEnvironment(simulator)" in ui and "SimulatorDiagnosticsView()" in ui,
    "simulator diagnostics execute automatically on launch": ".onAppear" in sim and "runner.run()" in sim,
    "speech.cpp and ggml logs reach the app": "speech_log_set(callback ? forward_speech_log : nullptr, nullptr)" in (root / "Sources/Haru4iOS/HaruBridge.mm").read_text() and "receiveRuntimeLog" in engine,
    "CPU backend comparison is available": "HaruRuntimeUnloadModel" in engine and 'Text("CPU").tag("cpu")' in ui,
    "model unload is guarded against active dialogue": "End the active dialogue before unloading the model" in (root / "Sources/Haru4iOS/HaruBridge.mm").read_text(),
}
failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + name)
if failed:
    raise SystemExit(1)
print(f"All {len(checks)} regression checks passed.")
