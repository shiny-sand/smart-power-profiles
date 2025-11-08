#!/usr/bin/env bash
# Smart Power Profiles installer / updater for Ubuntu 25.10+
# - Installs dependencies (power-profiles-daemon, Python GI, Ayatana AppIndicator, notify)
# - Installs scripts to ~/bin
# - Creates and enables user services (daemon + tray)
# - NOTE: No sandboxing directives in user units to avoid 218/CAPABILITIES errors

set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/bin"
DEST_DIR="$HOME/bin"
USER_SYSTEMD="$HOME/.config/systemd/user"

say()   { printf "%s\n" "$*"; }
hdr()   { printf "\n%s\n" "$*"; }
ok()    { printf "✅ %s\n" "$*"; }
info()  { printf "ℹ️  %s\n" "$*"; }
warn()  { printf "⚠️  %s\n" "$*"; }
err()   { printf "❌ %s\n" "$*"; }

need() { command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }; }

hdr "🚀 Installing Smart Power Profiles from $REPO_DIR"

# Ensure required folders
mkdir -p "$DEST_DIR" "$USER_SYSTEMD"

# Basic preflight
need systemctl
need sudo
need awk

hdr "📦 Installing dependencies (requires sudo)…"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
  power-profiles-daemon \
  python3-gi gir1.2-gtk-3.0 \
  gir1.2-ayatanaappindicator3-0.1 libayatana-appindicator3-1 \
  libnotify-bin lm-sensors bc || true

# Fallback to legacy AppIndicator only if Ayatana GI typelib is unavailable
if ! dpkg -s gir1.2-ayatanaappindicator3-0.1 >/dev/null 2>&1; then
  info "Ayatana GI typelib not found. Trying legacy AppIndicator typelib…"
  sudo apt-get install -y gir1.2-appindicator3-0.1 || true
fi

# Ensure power-profiles-daemon is active
if systemctl status power-profiles-daemon >/dev/null 2>&1; then
  ok "power-profiles-daemon service detected"
else
  info "Enabling power-profiles-daemon system service…"
  sudo systemctl enable --now power-profiles-daemon || true
fi

# Copy scripts (always overwrite with executable perms)
install -m 0755 "$SRC_DIR/auto-powerprofile.sh"   "$DEST_DIR/auto-powerprofile.sh"
install -m 0755 "$SRC_DIR/powerprofile-tray.py"   "$DEST_DIR/powerprofile-tray.py"
install -m 0755 "$SRC_DIR/debug-powerprofile.sh"  "$DEST_DIR/debug-powerprofile.sh"

# Enable lingering so user services start after login
info "Ensuring user lingering is enabled…"
sudo loginctl enable-linger "$USER" || true

# User services — minimal, stable, no hardening (avoids CAPABILITIES step)
cat > "$USER_SYSTEMD/smart-power-daemon.service" <<'EOF'
[Unit]
Description=Smart Power Profiles (auto switcher)
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=%h/bin/auto-powerprofile.sh
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1
Environment=XDG_RUNTIME_DIR=%t

[Install]
WantedBy=default.target
EOF

cat > "$USER_SYSTEMD/smart-power-tray.service" <<'EOF'
[Unit]
Description=Smart Power Profiles Tray
After=graphical-session.target
Wants=graphical-session.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 10
ExecStart=%h/bin/powerprofile-tray.py
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1
Environment=XDG_RUNTIME_DIR=%t

[Install]
WantedBy=default.target
EOF

# First-run sensors detect (safe, non-interactive) if sensors isn't usable yet
if ! sensors 1>/dev/null 2>&1; then
  hdr "🧪 Running a quick sensors-detect (non-interactive safe mode)…"
  sudo yes | sudo sensors-detect --auto || true
fi

# Reload systemd, enable & start services
hdr "🔄 Enabling user services…"
systemctl --user daemon-reload
systemctl --user enable --now smart-power-daemon.service smart-power-tray.service
ok "User services enabled and started."

# Verify Ayatana typelib presence for the tray
AYATANA_TYPLIB="/usr/lib/x86_64-linux-gnu/girepository-1.0/AyatanaAppIndicator3-0.1.typelib"
if [[ ! -f "$AYATANA_TYPLIB" ]]; then
  warn "Ayatana typelib not found at:"
  warn "  $AYATANA_TYPLIB"
  warn "The tray may fail with: No compatible AppIndicator binding found"
  warn "Packages commonly required: gir1.2-ayatanaappindicator3-0.1 libayatana-appindicator3-1 python3-gi gir1.2-gtk-3.0"
else
  ok "Ayatana typelib present"
fi

# Quick health check summary
hdr "🩺 Service health summary (last few lines)…"
if ! systemctl --user is-active --quiet smart-power-daemon.service; then
  systemctl --user status smart-power-daemon.service -n 20 || true
else
  ok "Daemon active"
fi
if ! systemctl --user is-active --quiet smart-power-tray.service; then
  systemctl --user status smart-power-tray.service -n 20 || true
else
  ok "Tray active"
fi

# Final tips
hdr "✅ Smart Power Profiles installed and running!"

cat <<'TIP'
Quick verification:
  ~/bin/debug-powerprofile.sh
  systemctl --user status smart-power-daemon.service
  systemctl --user status smart-power-tray.service
  journalctl --user -u smart-power-daemon.service -n 50 --no-pager

Notes:
- The daemon switches between power-saver / balanced / performance using CPU load
  (and optionally temperature + GPU if enabled in auto-powerprofile.sh).
- To silence notifications:   touch ~/.cache/powerprofile.silent
- Manual override:            echo performance > ~/.cache/powerprofile.override
  Return to auto:             rm -f ~/.cache/powerprofile.override
TIP
