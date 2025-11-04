#!/usr/bin/env bash
# Smart Power Profiles installer / updater for Ubuntu 25.10+

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/bin"
DEST_DIR="$HOME/bin"
USER_SYSTEMD="$HOME/.config/systemd/user"

echo "🚀 Installing Smart Power Profiles from $REPO_DIR"

# Ensure required folders
mkdir -p "$DEST_DIR" "$USER_SYSTEMD"

# Copy scripts
echo "📦 Copying scripts to $DEST_DIR..."
install -m 0755 "$SRC_DIR/auto-powerprofile.sh" "$DEST_DIR/auto-powerprofile.sh"
install -m 0755 "$SRC_DIR/powerprofile-tray.py" "$DEST_DIR/powerprofile-tray.py"

# ---------------------------------------------------------------------
# Create / update systemd user services
# ---------------------------------------------------------------------
echo "⚙️  Configuring systemd user services..."

# Daemon service
cat > "$USER_SYSTEMD/smart-power-daemon.service" <<EOF
[Unit]
Description=Smart Power Profiles Daemon
After=graphical-session.target

[Service]
ExecStart=%h/bin/auto-powerprofile.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF

# Tray service
cat > "$USER_SYSTEMD/smart-power-tray.service" <<EOF
[Unit]
Description=Smart Power Profiles Tray
After=graphical-session.target

[Service]
ExecStart=%h/bin/powerprofile-tray.py
Restart=always
RestartSec=2
Environment=DISPLAY=:0
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus

[Install]
WantedBy=default.target
EOF

# Reload systemd, enable & start services
systemctl --user daemon-reload
systemctl --user enable --now smart-power-daemon.service smart-power-tray.service

echo "✅ Smart Power Profiles installed and running!"
echo "🧠 You can manage services with:"
echo "   systemctl --user restart smart-power-daemon.service"
echo "   systemctl --user restart smart-power-tray.service"
echo
echo "💡 If you ever want to uninstall:"
echo "   systemctl --user disable --now smart-power-daemon.service smart-power-tray.service"
echo "   rm -f \$HOME/.config/systemd/user/smart-power-*.service"
