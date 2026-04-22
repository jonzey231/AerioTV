#!/bin/bash
#
# install-tunneld.sh — install `pymobiledevice3 remote tunneld` as a launchd
# daemon so the RemoteXPC tunnel to any paired Apple device is always available.
#
# Why a launchd daemon (not a login-time background process):
#   - tvOS 17+ / iOS 17+ devices speak RemoteXPC over a WireGuard-style tunnel
#     that requires root to create a `utun` interface. Running tunneld once as
#     root, under launchd, gives every user-space tool (this app's log
#     capture, `pymobiledevice3 syslog live`, lldb, Xcode on older versions)
#     tunnel access for free, without re-prompting for the admin password on
#     every rebuild.
#
# Usage: sudo ./install-tunneld.sh         # install + load + start
#        sudo ./install-tunneld.sh --uninstall
#
# After install, verify with:
#   sudo launchctl list | grep pymobiledevice3
#   pymobiledevice3 remote browse
#
# The plist lives at /Library/LaunchDaemons/app.molinete.aerio.tunneld.plist
# and stdout/stderr go to /var/log/aerio-tunneld.{out,err}.log — check there
# first if `remote browse` shows nothing.

set -eu

LABEL="app.molinete.aerio.tunneld"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
STDOUT_LOG="/var/log/aerio-tunneld.out.log"
STDERR_LOG="/var/log/aerio-tunneld.err.log"

# ─── Root check ───────────────────────────────────────────────────────────────

if [[ "$EUID" -ne 0 ]]; then
  echo "This script must be run with sudo."
  echo "Try: sudo $0"
  exit 1
fi

# ─── Uninstall path ───────────────────────────────────────────────────────────

if [[ "${1:-}" == "--uninstall" ]]; then
  if [[ -f "$PLIST" ]]; then
    launchctl bootout system "$PLIST" 2>/dev/null || \
      launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $PLIST"
  else
    echo "Nothing to uninstall ($PLIST not present)."
  fi
  exit 0
fi

# ─── Install path ─────────────────────────────────────────────────────────────

# Find pymobiledevice3. The symlink at /opt/homebrew/bin/pymobiledevice3 points
# at the user-specific pipx venv, but launchd daemons run as root and may not
# resolve a user symlink reliably — resolve to the concrete path now.
PMD3="$(readlink -f /opt/homebrew/bin/pymobiledevice3 2>/dev/null || true)"
if [[ -z "$PMD3" || ! -x "$PMD3" ]]; then
  PMD3="$(command -v pymobiledevice3 || true)"
fi
if [[ -z "$PMD3" ]]; then
  echo "Could not locate pymobiledevice3 executable."
  echo "Install it first: brew install pipx && pipx install pymobiledevice3"
  exit 1
fi

echo "Installing tunneld launchd daemon at $PLIST"
echo "  Using pymobiledevice3 at: $PMD3"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PMD3}</string>
        <string>remote</string>
        <string>tunneld</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${STDOUT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${STDERR_LOG}</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- pymobiledevice3 needs these for device discovery -->
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# Touch the log files so tunneld doesn't fail on first write due to perms.
touch "$STDOUT_LOG" "$STDERR_LOG"
chown root:wheel "$STDOUT_LOG" "$STDERR_LOG"
chmod 644 "$STDOUT_LOG" "$STDERR_LOG"

# Load. `bootstrap` is the modern replacement for `load`. Fall back if needed.
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load "$PLIST"

echo ""
echo "Installed. Verify with:"
echo "  sudo launchctl list | grep ${LABEL}"
echo "  pymobiledevice3 remote browse"
echo ""
echo "If 'remote browse' shows nothing after ~10 seconds, check:"
echo "  tail -50 $STDERR_LOG"
