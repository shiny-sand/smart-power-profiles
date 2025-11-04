#!/usr/bin/env bash
# Smart Power Profiles uninstaller for Ubuntu 25.10+
# - Stops and disables user services
# - Removes unit files and installed scripts
# - Cleans cache files
# - Optionally removes legacy sudoers snippet from older versions

set -euo pipefail

DEST_DIR="$HOME/bin"
USER_SYSTEMD="$HOME/.config/systemd/user"
SUDOERS_SNIPPET="/etc/sudoers.d/smart-power"

say()   { printf "%s\n" "$*"; }
hdr()   { printf "\n%s\n" "$*"; }
ok()    { printf "✅ %s\n" "$*"; }
info()  { printf "ℹ️  %s\n" "$*"; }
warn()  { printf "⚠️  %s\n" "$*"; }
err()   { printf "❌ %s\n" "$*"; }

hdr "🧹 Uninstalling Smart Power Profiles…"

# Ensure user systemd is available
if ! systemctl --user show-environment >/dev/null 2>&1; then
  warn "User systemd not detected. Run this inside your desktop session."
  exit 1
fi

# Stop and disable services
info "Stopping user services…"
systemctl --user disable --now smart-power-daemon.service smart-power-tray.service 2>/dev/null || true
systemctl --user reset-failed smart-power-daemon.service smart-power-tray.service 2>/dev/null || true

# Remove user systemd units
info "Removing user unit files…"
rm -f \
  "$USER_SYSTEMD/smart-power-daemon.service" \
  "$USER_SYSTEMD/smart-power-tray.service"

# Reload user systemd
systemctl --user daemon-reload || true

# Remove installed scripts
info "Removing installed scripts from $DEST_DIR…"
rm -f \
  "$DEST_DIR/auto-powerprofile.sh" \
  "$DEST_DIR/powerprofile-tray.py" \
  "$DEST_DIR/debug-powerprofile.sh"

# Clean cache
info "Cleaning cache files…"
rm -f \
  "$HOME/.cache/powerprofile.state" \
  "$HOME/.cache/powerprofile.last" \
  "$HOME/.cache/powerprofile.override" \
  "$HOME/.cache/powerprofile.silent" \
  "$HOME/.cache/powertop.last" \
  "$HOME/.cache/powerprofile.pt_until"

# Optional cleanup of an old sudoers snippet from legacy installs
if [[ -f "$SUDOERS_SNIPPET" ]]; then
  hdr "🛡️  Legacy configuration detected"
  say "An older version may have created $SUDOERS_SNIPPET for NOPASSWD powertop or cpupower."
  read -r -p "Remove $SUDOERS_SNIPPET now? [Y/n] " REPLY
  REPLY="${REPLY:-Y}"
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    if sudo rm -f "$SUDOERS_SNIPPET"; then
      ok "Removed $SUDOERS_SNIPPET"
    else
      warn "Could not remove $SUDOERS_SNIPPET. You can delete it manually with sudo."
    fi
  else
    info "Keeping $SUDOERS_SNIPPET."
  fi
fi

ok "Uninstalled Smart Power Profiles."
say ""
say "You can remove optional packages if you installed them only for this project:"
say "  sudo apt-get remove --purge libnotify-bin lm-sensors gir1.2-gtk-3.0 python3-gi gir1.2-ayatanaappindicator3-0.1 libayatana-appindicator3-1"
say "Power Profiles Daemon is part of Ubuntu by default, so it is usually best to keep it installed."
