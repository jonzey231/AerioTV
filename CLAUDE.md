# Aerio — notes for Claude Code

## Apple TV runtime logs

AerioTV stdout from the Apple TV 4K (3rd gen, "Living Room", CoreDevice id
`34C12C84-977F-51A9-B50B-7425ABCE2565`) is streamed to a file via
`xcrun devicectl device process launch --console`, wrapped in a PTY so that
`--console` actually captures app stdio.

**Log file:** `~/Library/Logs/AppleTV-Aerio.log`

**Primary reads Claude should use:**
```bash
# Just the current / latest run (delimited by "RUN START:" headers)
awk '/RUN START:/ {block=""} {block = block $0 "\n"} END {print block}' \
    ~/Library/Logs/AppleTV-Aerio.log | tail -n 400

# Per-phase MPV timing (setupMPV instrumentation) for the latest run
awk '/RUN START:/ {block=""} {block = block $0 "\n"} END {print block}' \
    ~/Library/Logs/AppleTV-Aerio.log \
  | grep -E "\[MPV-PHASE\]|\[MV-TIMING\]|\[MPV-ERR\]|\[MPV-WARMUP\]|First frame rendered" \
  | tail -n 100

# Check if a capture is currently running
pgrep -fl "xcrun devicectl.*--console.*app.molinete.aerio" || echo "no capture running"
```

## Starting / stopping a capture

**The Xcode Cmd+R workflow is UNCHANGED** — no post-action is wired in, because
devicectl launch fights with Xcode's debugger-attached launch. Use Cmd+R when
you want Xcode's debugger. Run the script below when you want logs Claude can
read.

```bash
# Start a capture in the background (kills any prior instance of the app + capture, starts fresh)
Scripts/capture-appletv-logs.sh

# Same but mirror stdout to terminal as well
Scripts/capture-appletv-logs.sh --foreground

# Tail the existing log
Scripts/capture-appletv-logs.sh --tail

# Stop the capture AND terminate the app on the device
Scripts/capture-appletv-logs.sh --stop
```

The capture uses Apple's CoreDevice framework via `xcrun devicectl`, so no
pairing setup is required — Xcode's existing device trust is reused.

## Overrides

- `AERIO_ATV_DEVICE` — CoreDevice id of a different Apple TV (default is the
  living-room one). Find new ids via `xcrun devicectl list devices`.
- `AERIO_ATV_BUNDLE_ID` — override the bundle id (default `app.molinete.aerio`).

## Startup-timing diagnostics recap (what's in the log)

- `[MPV-WARMUP]` — fires once per process launch. `MPVLibraryWarmup.warmUp()`
  creates+destroys a throwaway mpv handle during app startup so the first real
  `setupMPV` hits the warm path.
- `[MPV-PHASE] [tile=<id> <channel>] <phase>: Xms (total=Yms)` — per-phase
  timing inside `Coordinator.setupMPV` (MPVPlayerView.swift). Covers
  `mpv_create`, `pre_init_options`, `mpv_initialize`, `EAGLContext_create`,
  `EAGLContext_setCurrent`, `CVOpenGLESTextureCacheCreate`,
  `mpv_render_context_create`, `render_update_callback`,
  `observe_properties+wakeup`, `post_init_properties`.
- `[MV-TIMING] tile=<id> setup_ms=N headers=N cache_s=N isLive=bool rss=... fd=... thermal=... lpm=...`
  is the one-line per-tile summary.
- `First frame rendered (total time from setup: Xms)` is the tap-to-video
  latency. Last known good: **~2.1 s on LAN** with a warm process-wide init.

## pymobiledevice3 / tunneld (installed but not in use)

`sudo Scripts/install-tunneld.sh` is available if we ever re-try the
`pymobiledevice3 syslog live` route. The Apple TV in this network refuses to
advertise `_remotepairing-manual-pairing._tcp` reliably, so pair-by-bonjour
doesn't complete. Uninstalling is `sudo Scripts/install-tunneld.sh --uninstall`.
Leaving it installed is harmless (idle launchd daemon).
