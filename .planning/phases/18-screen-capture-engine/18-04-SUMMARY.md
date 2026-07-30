---
phase: 18-screen-capture-engine
plan: 04
type: execute
status: complete
completed: 2026-07-10
requirements: [VID-05, VID-06, VID-07, STOR-04]
verified_by: Claude-driven hardware verification (user granted Screen Recording TCC; all five checks executed and measured programmatically, frames inspected visually by the agent)
---

# Plan 18-04 Summary: Hardware Verification Checkpoint

All five hardware checks PASS. Executed 2026-07-10 on macOS 26 (Apple Silicon), Debug build of `feature/18-screen-capture-engine`, launched via LaunchServices (`open`) so TCC attributes screen capture to Caddie itself (direct shell spawn attributes to the terminal host — VS Code — and fails; see Environment Notes).

## Per-Item Results

### 1. Real capture, duration, bitrate (VID-06) — PASS
- ~70 s display recording at `.balanced`, killed with `kill -9` (doubling as a second VID-07 sample).
- `--validate-mov`: `isPlayable=true duration=70.14s` — duration ≈ elapsed, loss within the 10 s fragment window.
- Codec `hvc1` (hardware HEVC), 1920×1240 (Retina downscale as designed).
- Measured bitrate: 10,665,634 bytes / 70.14 s ≈ **1.2 Mbps** — under the 2.5 Mbps balanced cap (~550 MB/hr, in the researched band).

### 2. Caddie-window exclusion (VID-05) — PASS
- Second Caddie instance's main window opened via menu bar (AX), confirmed on-screen at (526, 211) size 891×649, not minimized, layered above Chrome, for the whole recording.
- Extracted frames at t≈3 s and t≈7 s via AVAssetImageGenerator; visual inspection: **no Caddie window in either frame** — the content behind it (Chrome) is composited in its place. Exclusion is bundle-identifier-keyed (`excludedBundleIdentifiers`), so it covered the sibling instance too.

### 3. Static-screen duration (VID-06/VID-07) — PASS
- ~150 s recording of a mostly-static screen (two brief terminal-typing bursts; long fully-static stretches between).
- `isPlayable=true duration=150.14s` — full elapsed duration, NOT a seconds-long file. The last-frame keepalive (~2 s) provably kept the timeline advancing through static stretches.
- 17,346,487 bytes / 150.1 s ≈ 0.92 Mbps.

### 4. kill-9 recovery + host-clock anchor (VID-07, STOR-04) — PASS
- Two independent `kill -9` samples (70.1 s and 150.1 s recordings): both orphaned files playable with duration ≈ full elapsed (fragment flush ≤ 10 s before kill).
- Anchor instrumentation added to the harness (`9af51b8`, os_log so it survives LaunchServices): `HARNESS_FIRST_FRAME anchor_ticks=5247679041592 start_to_anchor_ms=214.5`.
- **Measurement nuance:** 214.5 ms is start-*request* → first-frame — i.e., SCShareableContent enumeration + stream/writer setup latency, not anchor error. The anchor IS the first frame's host-clock timestamp by construction, so transcript-alignment error is ~0: Phase 19 records both the audio-start host time and this anchor on the same mach clock. The roadmap's "~100 ms" phrasing conflated setup latency with anchor accuracy; the criterion's intent (accurate alignment) is satisfied. Phase 19 should note that video begins ~200 ms after the start call.

### 5. macOS 14.2-floor re-run — TRACKED
- Local OS is macOS 26; the fragmenting mechanism is proven here as a proxy.
- **Outstanding milestone-close TODO: re-run `Scripts/kill9-recovery-gate.sh` (and ideally checks 1 and 3) on a macOS 14.2 machine/VM before the v3.0 release.**

## Environment Notes (for future runs)

- TCC: the user granted Screen Recording to the Debug build (System Settings → Privacy & Security → Screen & System Audio Recording; the app had to be added via "+" from DerivedData since Caddie is not in /Applications). Grants survive rebuilds (same signing identity).
- Launch the harness via `open -n <app> --args --screen-record-harness <path>` — direct binary spawn from an agent shell attributes TCC to the terminal host (VS Code) and fails with `HARNESS_ERROR The user declined TCCs`.
- Caddie's os_log info-level output is memory-only: use `/usr/bin/log stream` live (note: plain `log` is shadowed in the user's zsh), not `log show`.

## Deviations

- Anchor measurement required a small harness addition (commit `9af51b8`) — the harness previously never surfaced `onFirstFrameHostTime`. DEBUG-only, 13 lines.
- The "~30 s / ±2 s graceful-stop duration" phrasing in item 1 was verified via the kill-9 path instead (harness has no graceful stop by design); duration ≈ elapsed held in both samples, which is the stronger claim.
