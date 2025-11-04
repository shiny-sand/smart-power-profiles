#!/usr/bin/env bash
# Smart Power Profiles uninstaller for Ubuntu 25.10+
# Safely removes systemd user services and installed scripts from ~/bin

set -euo pipefail

DEST_DIR="$HOME/bin"
USER_SYSTEMD="$HOME/.config/systemd/user"

echo "🧹 Uninstalling Smart Power Profiles..."

# Ensure user systemd is available
if ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "⚠️ User systemd not detected. Run this inside your desktop session."
  exit 1
fi

# Stop and disable user services in correct order
for svc in smart-power-tray.service smart-power-daemon.service; do
  if systemctl --user list-unit-files | grep -q "$svc"; then
    echo "⚙️  Disabling and stopping $svc..."
    systemctl --user disable "$svc" >/dev/null 2>&1 || true
    systemctl --user stop "$svc" >/dev/null 2>&1 || true
  fi
done

# Wait briefly for any lingering processes
sleep 0.5

# Double-check and kill any leftover processes
echo "🔪 Killing any remaining background processes..."
pkill -f "[a]uto-powerprofile.sh" || true
pkill -f "[p]owerprofile-tray.py" || true

# Remove systemd service files
echo "🗑️  Removing systemd service files..."
rm -f "$USER_SYSTEMD/smart-power-daemon.service" "$USER_SYSTEMD/smart-power-tray.service"
systemctl --user daemon-reload

# Remove scripts
echo "🧼 Removing scripts from $DEST_DIR..."
rm -f "$DEST_DIR/auto-powerprofile.sh" "$DEST_DIR/powerprofile-tray.py"

# Remove cached state and override
echo "🧽 Cleaning cached files..."
rm -f "$HOME/.cache/powerprofile.state" "$HOME/.cache/powerprofile.override"

echo "✅ Smart Power Profiles fully removed."

echo
echo "💡 You can confirm no processes remain with:"
echo "   pgrep -fal powerprofile"
echo
echo "If you cloned the repo and no longer need it:"
echo "   rm -rf ~/Projects/smart-power-profiles"
