#!/bin/bash
#
# capture-appletv-logs.sh — launch AerioTV on the Apple TV with stdio captured
# to a file that Claude Code can tail.
#
# Why this instead of pymobiledevice3: Apple TV 4K (3rd gen, tvOS 17+) doesn't
# always advertise the `_remotepairing-manual-pairing._tcp` Bonjour service
# that pymobiledevice3 needs to establish an RSD pair — it only advertises it
# while a specific Settings screen is open on the TV. `xcrun devicectl` reuses
# Apple's CoreDevice trust (already set up by Xcode) so no pairing dance.
#
# Trade-off: this launches the app itself (not the debugger-attached build).
# It bypasses Xcode's Run action, so no breakpoints / LLDB while capturing.
# Use Cmd+R for normal debugging; use this script when you want logs for
# Claude to read.
#
# Modes:
#   (no args)       — background: start capture, return immediately, log to file
#   --foreground    — interactive: same capture, also mirror to stdout
#   --tail          — follow the existing log file (no relaunch)
#   --stop          — terminate any running capture AND the app
#
# Writes to: ~/Library/Logs/AppleTV-Aerio.log

set -u

# ─── Config ───────────────────────────────────────────────────────────────────

# Apple TV 4K (3rd gen) "Living Room" — CoreDevice UUID (NOT the tvOS UDID).
# `xcrun devicectl list devices` prints the right identifier in the
# "Identifier" column. Override with env var if you add more devices.
DEFAULT_DEVICE="34C12C84-977F-51A9-B50B-7425ABCE2565"
DEVICE="${AERIO_ATV_DEVICE:-$DEFAULT_DEVICE}"

# Bundle id of the tvOS target.
BUNDLE_ID="${AERIO_ATV_BUNDLE_ID:-app.molinete.aerio}"

LOG_FILE="$HOME/Library/Logs/AppleTV-Aerio.log"

# ─── Helpers ──────────────────────────────────────────────────────────────────

kill_existing_capture() {
  # Match on the full script command so we don't kill random devicectl calls.
  pkill -f "script .* xcrun devicectl .* --console .* ${BUNDLE_ID}" >/dev/null 2>&1 || true
  # Give any survivors a moment to exit cleanly.
  sleep 0.3
}

terminate_app_on_device() {
  # Find the current AerioTV pid on the TV, if any, and SIGTERM it so the next
  # devicectl launch owns stdio.
  local pid
  pid="$(xcrun devicectl device info processes --device "$DEVICE" 2>/dev/null \
         | awk '/Aerio\.app\/Aerio$/ {print $1; exit}')"
  if [[ -n "${pid:-}" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE" --pid "$pid" \
      >/dev/null 2>&1 || true
  fi
}

rotate_if_large() {
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if (( size > 20_971_520 )); then   # 20 MB
      mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
    fi
  fi
}

write_run_header() {
  local mode="$1"
  {
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "RUN START: $(date '+%Y-%m-%d %H:%M:%S')  mode=$mode  device=$DEVICE"
    echo "Bundle id: $BUNDLE_ID"
    echo "═══════════════════════════════════════════════════════════════════"
  } >> "$LOG_FILE"
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if ! command -v xcrun >/dev/null 2>&1; then
  echo "[capture-appletv-logs] xcrun not found — need Xcode command-line tools." >&2
  exit 1
fi

# ─── Mode switch ──────────────────────────────────────────────────────────────

mode="${1:-background}"

case "$mode" in
  --foreground|-f)   mode="foreground" ;;
  --tail|-t)         mode="tail" ;;
  --stop|-s)         mode="stop" ;;
  background|"")     mode="background" ;;
  *)
    echo "Unknown mode: $mode"
    echo "Usage: $0 [--foreground|--tail|--stop]"
    exit 2
    ;;
esac

case "$mode" in
  stop)
    kill_existing_capture
    terminate_app_on_device
    echo "[capture-appletv-logs] Capture stopped; app terminated on device."
    exit 0
    ;;
  tail)
    if [[ ! -f "$LOG_FILE" ]]; then
      echo "[capture-appletv-logs] No log file yet at $LOG_FILE"
      exit 1
    fi
    # Passthrough — user can Ctrl+C
    exec tail -n 50 -f "$LOG_FILE"
    ;;
esac

# Background / foreground: both need a clean slate.
kill_existing_capture
terminate_app_on_device
rotate_if_large
write_run_header "$mode"

# ─── Launch via devicectl wrapped in a PTY ────────────────────────────────────
#
# `script -q /dev/null` provides a pseudo-terminal, which `devicectl --console`
# needs in order to actually pipe the app's stdout/stderr. Without the PTY,
# --console runs but emits no app output (proven earlier — empty file).
# `-q` suppresses script's own banner; `/dev/null` is the discarded typescript.

LAUNCH_CMD=(
  script -q /dev/null
  xcrun devicectl device process launch
    --console
    --device "$DEVICE"
    "$BUNDLE_ID"
)

if [[ "$mode" == "foreground" ]]; then
  # Stream to stdout AND append to the file. stdbuf keeps tee line-buffered so
  # the file reflects every line the instant it's printed.
  "${LAUNCH_CMD[@]}" 2>&1 | stdbuf -oL tee -a "$LOG_FILE"
else
  # Detach fully: nohup, stdin closed, stdout+stderr append to file, disown.
  nohup "${LAUNCH_CMD[@]}" >>"$LOG_FILE" 2>&1 </dev/null &
  capture_pid=$!
  disown
  echo "[capture-appletv-logs] Capture started (pid=$capture_pid)"
  echo "[capture-appletv-logs] Log: $LOG_FILE"
  echo "[capture-appletv-logs] Tail: $0 --tail"
  echo "[capture-appletv-logs] Stop: $0 --stop"
fi
