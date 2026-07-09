#!/usr/bin/env bash
set -euo pipefail

# kill9-recovery-gate.sh — VID-07 crash-safety gate for ScreenRecorder.
#
# Proves that a `kill -9` mid-recording leaves a PLAYABLE fragmented `.mov`
# missing AT MOST the last ~10 s (one movieFragmentInterval). This cannot be an
# XCTest: an XCTest process cannot cleanly `kill -9` itself and still assert, so
# the gate is shell-driven against the DEBUG headless harness
# (ScreenRecorderHarness, reached via `--screen-record-harness` / `--validate-mov`).
#
# Steps (per 18-VALIDATION.md "kill-9 recovery gate"):
#   1. Build the Debug app, resolve the binary inside the .app bundle.
#   2. Launch `--screen-record-harness <out.mov>`; wait for `HARNESS_READY pid=`.
#   3. Record >= 3 fragment intervals (30 s), then `kill -9` the harness pid.
#   4. Validate with `--validate-mov`: assert isPlayable AND duration >= 30 - 10.
#
# Requires: Screen Recording permission (already granted to Caddie) + a REAL
# display. NOT part of `make test` CI. Run manually:  bash scripts/kill9-recovery-gate.sh
#
# --static : same flow, but the operator leaves the screen STATIC to exercise the
#            keepalive re-append path (movieFragmentInterval must keep flushing on
#            static content). The same duration assertion applies.

# ---------------------------------------------------------------------------
# 14.2 FLOOR BANNER — READ THIS
# ---------------------------------------------------------------------------
cat <<'BANNER'
================================================================================
NOTE: the local OS is NOT the macOS 14.2 deployment floor. This gate proves the
.mov + movieFragmentInterval fragmenting mechanism on the available OS as a proxy.
It MUST be re-run on a macOS 14.2 machine/VM before milestone release
(per 18-VALIDATION.md "Manual-Only Verifications").
================================================================================
BANNER

STATIC_MODE=0
if [[ "${1:-}" == "--static" ]]; then
    STATIC_MODE=1
    echo "==> --static mode: leave the screen UNTOUCHED for the recording window."
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

RECORD_SECS=30          # >= 3 fragment intervals of 10 s
MIN_DURATION=$((RECORD_SECS - 10))   # allow losing at most the last fragment
READY_TIMEOUT=15        # seconds to wait for HARNESS_READY

# --- 1. Build the Debug app and resolve the binary ---------------------------
echo "==> Building Debug app..."
xcodegen generate >/dev/null
xcodebuild build \
    -project Caddie.xcodeproj \
    -scheme Caddie \
    -configuration Debug \
    -destination 'platform=macOS' >/dev/null

BUILT_PRODUCTS_DIR="$(xcodebuild -project Caddie.xcodeproj -scheme Caddie \
    -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
EXECUTABLE_PATH="$(xcodebuild -project Caddie.xcodeproj -scheme Caddie \
    -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ EXECUTABLE_PATH /{print $2; exit}')"
BIN="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}"

if [[ ! -x "$BIN" ]]; then
    echo "GATE FAIL: Debug binary not found/executable at: $BIN" >&2
    exit 1
fi
echo "==> Binary: $BIN"

# --- 2. Launch the harness and wait for readiness ----------------------------
WORKDIR="$(mktemp -d -t caddie-kill9)"
OUT="${WORKDIR}/recording.mov"
LOG="${WORKDIR}/harness.log"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Launching harness -> $OUT"
"$BIN" --screen-record-harness "$OUT" >"$LOG" 2>&1 &
SHELL_PID=$!

PID=""
for _ in $(seq 1 "$READY_TIMEOUT"); do
    if ! kill -0 "$SHELL_PID" 2>/dev/null; then
        echo "GATE FAIL: harness exited before becoming ready. Log:" >&2
        cat "$LOG" >&2
        exit 1
    fi
    # Prefer the pid printed on the HARNESS_READY line (binary may re-exec).
    if grep -q "HARNESS_READY" "$LOG" 2>/dev/null; then
        PID="$(sed -n 's/.*HARNESS_READY pid=\([0-9]*\).*/\1/p' "$LOG" | head -1)"
        break
    fi
    if grep -q "HARNESS_ERROR" "$LOG" 2>/dev/null; then
        echo "GATE FAIL: harness reported HARNESS_ERROR (likely missing Screen Recording permission or no display):" >&2
        cat "$LOG" >&2
        exit 1
    fi
    sleep 1
done

if [[ -z "$PID" ]]; then
    echo "GATE FAIL: harness never printed HARNESS_READY within ${READY_TIMEOUT}s. Log:" >&2
    cat "$LOG" >&2
    kill -9 "$SHELL_PID" 2>/dev/null || true
    exit 1
fi
echo "==> Harness ready (pid=$PID). Recording ${RECORD_SECS}s..."
[[ "$STATIC_MODE" -eq 1 ]] && echo "    (static mode: do not touch the screen)"

# --- 3. Record, then kill -9 mid-recording -----------------------------------
sleep "$RECORD_SECS"
echo "==> kill -9 $PID"
kill -9 "$PID" 2>/dev/null || true
# Reap whatever shell-level child we spawned.
wait "$SHELL_PID" 2>/dev/null || true
sleep 1

if [[ ! -f "$OUT" ]]; then
    echo "GATE FAIL: no output file produced at $OUT" >&2
    exit 1
fi

# --- 4. Validate the partial file --------------------------------------------
echo "==> Validating $OUT ..."
set +e
VALIDATE_OUT="$("$BIN" --validate-mov "$OUT" 2>&1)"
VALIDATE_CODE=$?
set -e
echo "$VALIDATE_OUT"

DURATION="$(printf '%s\n' "$VALIDATE_OUT" | sed -n 's/.*duration=\([0-9.]*\).*/\1/p' | head -1)"
DURATION="${DURATION:-0}"

# PASS: validator exit 0 (isPlayable) AND duration >= RECORD_SECS - 10.
DUR_OK="$(awk -v d="$DURATION" -v m="$MIN_DURATION" 'BEGIN { print (d + 0 >= m) ? 1 : 0 }')"

if [[ "$VALIDATE_CODE" -eq 0 && "$DUR_OK" -eq 1 ]]; then
    echo "GATE PASS: playable partial, duration=${DURATION}s (>= ${MIN_DURATION}s; lost <= last fragment)."
    exit 0
else
    echo "GATE FAIL: validate_exit=${VALIDATE_CODE} duration=${DURATION}s (need exit 0 and duration >= ${MIN_DURATION}s)." >&2
    exit 1
fi
