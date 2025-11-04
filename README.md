# 🧠 Smart Power Profiles for Linux

**Smart Power Profiles** automatically switches between **power-saver**, **balanced**, and **performance** modes on GNOME desktops.  
It monitors CPU load, temperature, and GPU activity — boosting performance when you need it and saving watts when you don’t.  
A small tray icon (🌙 ⚙️ ⚡) lets you override or return to auto mode at any time.

---

## ✨ Features
- **Automatic profile switching** based on CPU load, temperature, and NVIDIA GPU usage  
- **Tray indicator** for manual control and quick status view  
- **Manual override system** (lock any profile or clear override to resume auto)  
- **GPU-aware** (detects heavy gaming or rendering)  
- **Process awareness** (auto-boost when Steam, OBS, Blender, etc. are open)  
- **Powertop auto-tuning** when entering power-saver mode  
- **Pure Bash + Python**, no daemons or root services required  

---

## 🧩 Components

| File | Role |
|------|------|
| `bin/auto-powerprofile.sh` | Background daemon. Checks CPU/GPU load and temperature every few seconds and calls `powerprofilesctl` accordingly. |
| `bin/powerprofile-tray.py` | Tray application showing 🌙 ⚙️ ⚡ and allowing manual control or “Auto” mode. |
| `~/.cache/powerprofile.override` | Manual override file (created when you pick a fixed profile). |
| `~/.cache/powerprofile.state` | Stores the last applied mode (read by the tray). |

---

## ⚙️ Requirements

Ubuntu 25.10 (or any modern GNOME-based distro).

```bash
sudo apt install power-profiles-daemon powertop lm-sensors bc \
  python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 \
  libayatana-appindicator3-1 nvidia-utils-550
```

Enable AppIndicator support:

```bash
gnome-extensions enable ubuntu-appindicators@ubuntu.com
```

---

## 🚀 Installation

```bash
git clone https://github.com/shiny-sand/smart-power-profiles.git
cd smart-power-profiles
chmod +x bin/auto-powerprofile.sh bin/powerprofile-tray.py
```

Test manually:

```bash
./bin/auto-powerprofile.sh &
./bin/powerprofile-tray.py &
```

You should see the tray icon appear in the top-right panel.

---

## 🔧 Autostart at Login

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/smart-power-daemon.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Smart Power Daemon
Exec=/home/YOURUSERNAME/Projects/smart-power-profiles/bin/auto-powerprofile.sh
X-GNOME-Autostart-enabled=true
EOF

cat > ~/.config/autostart/smart-power-tray.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Smart Power Tray
Exec=/home/YOURUSERNAME/Projects/smart-power-profiles/bin/powerprofile-tray.py
X-GNOME-Autostart-enabled=true
EOF
```

Replace `YOURUSERNAME` with your login name, then re-log.

---

## 🪄 Usage

- 🌙 **Power-Saver** – lowest power draw; triggers at idle  
- ⚙️ **Balanced** – default everyday mode  
- ⚡ **Performance** – activates under heavy CPU/GPU load or when specific apps run  
- 🧠 **Auto Mode** – lets the daemon decide dynamically  

**Manual override:**  
Pick any mode from the tray menu; it stays fixed until you select **Auto** again.

---

## 🧠 How Auto Mode Works

1. The daemon samples metrics every 10 s.  
2. Thresholds determine which profile to activate.  
3. When you select a fixed mode, the tray writes `~/.cache/powerprofile.override`.  
4. The daemon pauses automatic switching while that file exists.  
5. Choosing *Auto* deletes the file; the daemon resumes control.  
6. The active mode is recorded in `~/.cache/powerprofile.state`.

---

## 🧮 Configuration

Edit thresholds near the top of `auto-powerprofile.sh`:

```bash
LOAD_BALANCED=1.0
LOAD_PERF=4.0
TEMP_BALANCED=50
TEMP_PERF=70
GPU_UTIL_BALANCED=15
GPU_UTIL_PERF=40
GPU_PWR_PERF=90
CHECK_INTERVAL=10
FORCE_PERF_PROCS="steam|obs|resolve|blender|davinci|gamescope|proton"
```

Restart the daemon after changes.

---

## 🧰 Optional systemd (user) service

`~/.config/systemd/user/smart-power-daemon.service`

```ini
[Unit]
Description=Smart Power Profiles Daemon
After=graphical-session.target

[Service]
ExecStart=%h/Projects/smart-power-profiles/bin/auto-powerprofile.sh
Restart=always

[Install]
WantedBy=default.target
```

Enable it:

```bash
systemctl --user enable --now smart-power-daemon.service
```

---

## 🧭 Roadmap
- GPU temperature support  
- Battery/UPS integration  
- JSON rules for per-app profiles  
- GNOME Shell extension for native UI  
- Flatpak / DEB packaging  

---

## 📄 License
MIT © 2025 shiny-sand  
Free to use, modify, and distribute with attribution.

---

## 💬 Contributing
Pull requests are welcome!  
When reporting issues, include:
- Distro + GNOME version  
- Expected vs actual behavior  
- `~/.cache/powerprofile.state` contents

---

### ❤️ Credits
Created by **shiny-sand** with help from ChatGPT (GPT-5).  
Inspired by the idea that desktops deserve laptop-grade efficiency.