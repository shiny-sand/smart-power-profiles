# Smart Power Profiles

Smart Power Profiles automatically adjusts CPU and GPU performance modes on Ubuntu 25.10 based on system load, temperature, and running applications. It also includes a lightweight tray indicator for quick manual switching.

---

## ⚙️ Features

- Dynamic auto-switching between **power-saver**, **balanced**, and **performance** profiles
- Tray indicator with emoji status 🌙 ⚙️ ⚡
- Manual override with automatic resume (“Auto”)
- Systemd integration for clean startup and management
- Optional Powertop tuning when entering power-saver mode

---

## 📦 Installation & Updates

Clone and install (first time or to update to the latest version):

```bash
git clone https://github.com/shiny-sand/smart-power-profiles.git
cd smart-power-profiles
./install.sh
```

The installer will:

- Copy scripts to `~/bin/`
- Create/update the **systemd --user** services
- Enable and start them for your current user

You can safely re-run `./install.sh` any time to redeploy updates.

---

## 🧩 Services (recommended)

Both components run as **systemd --user** services for reliable startup on login and easy restarts.

### Daemon service
`~/.config/systemd/user/smart-power-daemon.service`
```ini
[Unit]
Description=Smart Power Profiles Daemon
After=graphical-session.target

[Service]
ExecStart=%h/bin/auto-powerprofile.sh
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

### Tray service
`~/.config/systemd/user/smart-power-tray.service`
```ini
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
```

Enable (or restart) services:

```bash
systemctl --user daemon-reload
systemctl --user enable --now smart-power-daemon.service smart-power-tray.service

# later, when updating:
systemctl --user restart smart-power-daemon.service smart-power-tray.service
```

This **replaces older `.desktop` autostart** methods.  
If you previously created autostart entries, you can remove them:

```
~/.config/autostart/powerprofile-tray.desktop
~/.local/share/applications/powerprofile-tray.desktop
```

---

## 🧠 Usage

- The tray icon shows the current mode via emoji:
  - 🌙 **power-saver**
  - ⚙️ **balanced**
  - ⚡ **performance**
- Click the tray icon to pick a mode or choose **Auto (remove override)** to let the daemon manage switching again.
- The current active profile is stored in `~/.cache/powerprofile.state`.
- If Powertop is installed, auto-tuning will be applied on entry to power-saver mode.

---

## 🧹 Troubleshooting

- On GNOME + Wayland, a small “…” placeholder can appear next to the emoji in the tray. This is a harmless quirk of the AppIndicator host and does not affect functionality.
- Verify services are active:
  ```bash
  systemctl --user status smart-power-daemon.service
  systemctl --user status smart-power-tray.service
  ```
- If you don’t see the tray icon, ensure the **AppIndicator** extension is enabled (Ubuntu enables it by default).

---

## 🧾 License

MIT License © 2025 shiny-sand