# Smart Power Profiles (Ubuntu 25.10+)

Save watts when your desktop is idle and snap to full performance when you start real work.  
This project drives **power-profiles-daemon** using a tiny shell daemon and a tray helper. No powertop, no kernel tweaks, no sudoers hacks.

> Runs as user services in your desktop session. Works great on powerful desktops that should be quiet at idle and fast under load.

---

## Highlights

- Auto switches between **power-saver**, **balanced**, and **performance** using CPU load with hysteresis.
- Optional **spike accelerator** so brief bursts can jump to performance quickly.
- Optional **GPU utilization** awareness (NVIDIA via `nvidia-smi`, AMD via `gpu_busy_percent`) so 3D wakes performance fast.
- Optional **GPU temperature** trigger (default on) so performance engages if the GPU goes above a small threshold.
- Optional **CPU temperature** awareness if you want to de-rate under sustained heat.
- **Text-only tray** shows current mode and lets you toggle Auto or pick a mode manually.
- Safe by default: runs in user space, writes small state files in `~/.cache`, and uses conservative systemd hardening.

---

## Requirements

- Ubuntu 25.10 or newer (GNOME session). It may work on other recent distros that ship power-profiles-daemon.
- Packages are installed by the installer:
  - `power-profiles-daemon`
  - `python3-gi`, `gir1.2-gtk-3.0`
  - `gir1.2-ayatanaappindicator3-0.1`, `libayatana-appindicator3-1` (tray)
  - `libnotify-bin` (notifications), `lm-sensors`, `bc`
- Optional for GPU integration:
  - NVIDIA: `nvidia-smi` present from the proprietary driver.
  - AMD: `/sys/class/drm/*/gpu_busy_percent` from amdgpu driver.

---

## Install

Clone or copy this repo, then run the installer from the project root:
```bash
./install.sh
```

What it does:
- Installs dependencies with `apt`.
- Installs scripts to `~/bin`:
  - `auto-powerprofile.sh` (daemon)
  - `powerprofile-tray.py` (tray)
  - `debug-powerprofile.sh` (quick status)
- Creates and enables these **user** systemd units:
  - `smart-power-daemon.service`
  - `smart-power-tray.service`

Services start immediately in your session. You can verify:

```bash
systemctl --user status smart-power-daemon.service
systemctl --user status smart-power-tray.service
```

---

## Uninstall

From the project root:
```bash
./uninstall.sh
```

It stops and disables the user services, removes unit files and scripts, and cleans cache files under `~/.cache`.

---

## How it decides modes

The daemon reads a few simple signals every couple of seconds and decides which profile to apply.

- **CPU load (1-minute)** guides the baseline mode with **hysteresis** so it does not flap.
- **Spike accelerator** uses a short CPU busy percentage to catch sudden bursts.
- Optional **GPU utilization** promotes faster boosts when you start 3D or compute.
- Optional **GPU temperature** trigger promotes to performance when the GPU warms up.
- Optional **CPU temperature** can be used to avoid staying in performance if things get hot for a long time.

A tiny cache in `~/.cache` is written for the tray:

- `powerprofile.state`  the current effective profile
- `powerprofile.last`   the last target the daemon tried to set
- `powerprofile.override` a manual mode if you want to force a profile
- `powerprofile.silent` presence disables notifications

---

## Quickstart for desktops

The defaults are tuned for a powerful desktop that should idle low and boost quickly.

- Check live decisions:
  ```bash
  ~/bin/debug-powerprofile.sh
  journalctl --user -fu smart-power-daemon.service
  ```

- Force a manual profile (until you remove the override file):
  ```bash
  echo performance > ~/.cache/powerprofile.override
  # back to auto:
  rm -f ~/.cache/powerprofile.override
  ```

- Silence popups:
  ```bash
  touch ~/.cache/powerprofile.silent
  ```

- Tray tips:
  - The tray shows `A: Balanced` or `M: Performance` etc. A means Auto, M means Manual.
  - Toggle Auto in the tray or pick a profile. Manual writes the override file for you.

---

## Configuration knobs

Edit `~/bin/auto-powerprofile.sh` and adjust the block near the top. Then restart the daemon:

```bash
systemctl --user restart smart-power-daemon.service
```

Default desktop-biased settings:

```bash
# Main cadence
CHECK_INTERVAL=2

# CPU thresholds (load averages)
LOAD_PERF_ENTER=4.0   # go to performance when 1m load >= 4.0
LOAD_PERF_EXIT=2.5    # leave performance when 1m load < 2.5
LOAD_BAL_ENTER=1.2    # go to balanced when 1m load >= 1.2
LOAD_BAL_EXIT=0.5     # leave balanced for power-saver when 1m load < 0.5

# Spike accelerator (short busy% heuristic)
SPIKE_ACCEL_FRACTION=0.85
SPIKE_CPU_BUSY_PCT_BASE_MULT=20

# GPU utilization awareness (off by default)
GPU_AWARE=0
GPU_PERF_ENTER=50
GPU_PERF_EXIT=35
GPU_BAL_ENTER=15
GPU_BAL_EXIT=5

# CPU temperature awareness (off by default)
TEMP_AWARE=0
TEMP_PERF_ENTER=80
TEMP_PERF_EXIT=70
TEMP_BAL_ENTER=60
TEMP_BAL_EXIT=45

# GPU temperature trigger (on by default)
GPU_TEMP_AWARE=1
GPU_TEMP_PERF_ENTER=37  # promote to performance at or above 37 C
```

### Notes on inputs

- **CPU load** comes from `/proc/loadavg` (1 minute) for stability.
- **Short busy%** comes from `/proc/stat` deltas and is a quick hint to catch spikes.
- **GPU util**:
  - NVIDIA: `nvidia-smi --query-gpu=utilization.gpu` (max of all GPUs).
  - AMD: max value from `/sys/class/drm/*/gpu_busy_percent`.
- **GPU temperature**:
  - Tries **hwmon** first: it scans `/sys/class/hwmon` for `nvidia` or `amdgpu` entries and reads `temp*_input` values.
  - Falls back to `nvidia-smi --query-gpu=temperature.gpu` if hwmon lookup fails.
- **CPU temperature** tries `sensors` first and then `thermal_zone0` as a fallback.

---

## Debugging

- See what the script is deciding in real time:
  ```bash
  journalctl --user -fu smart-power-daemon.service
  ```
- Inspect the current profile:
  ```bash
  powerprofilesctl get
  ```
- Check tray messages if it does not show up:
  ```bash
  systemctl --user status smart-power-tray.service
  ```
- Verify Ayatana typelib is present (for the tray):
  ```bash
  ls /usr/lib/x86_64-linux-gnu/girepository-1.0/AyatanaAppIndicator3-0.1.typelib
  ```
- Verify sensors:
  ```bash
  sensors
  ```

---

## Service control

All services are user services. No sudo needed here:

```bash
systemctl --user restart smart-power-daemon.service
systemctl --user restart smart-power-tray.service

systemctl --user stop smart-power-daemon.service
systemctl --user disable smart-power-daemon.service
systemctl --user enable smart-power-daemon.service
```

If you change packages or libraries, re-run `./install.sh` to refresh dependencies and units.

---

## Security model

- No root privileges while running.
- Uses systemd hardening such as `NoNewPrivileges` and `PrivateTmp`. Home remains writable because the daemon uses `~/.cache`.
- State files under `~/.cache` are small and have restrictive permissions (`umask 077`).

---

## FAQ

**Will this drain my battery on a laptop?**  
It is tuned for desktops by default. It still works on laptops. If you want to be more aggressive about power saving, raise the thresholds a little and increase `LOAD_BAL_EXIT` to drop back to power-saver sooner.

**Why is YouTube not triggering performance?**  
Video playback usually uses the decoder block, which is very efficient and keeps GPU temps and utilization low. That is good. You still get boosts when CPU load spikes or when 3D starts.

**How do I force a profile for testing?**  
Write to the override file:
```bash
echo performance > ~/.cache/powerprofile.override
# back to auto
rm -f ~/.cache/powerprofile.override
```

**Do I need powertop or cpupower?**  
No. Everything is done via `powerprofilesctl`.

**Where are logs?**  
Use `journalctl --user -u smart-power-daemon.service` and `journalctl --user -u smart-power-tray.service`.

---

## License

MIT. See `LICENSE` if present. If not, treat the scripts as MIT licensed by default.

---

## Credits

Built with love for quiet desktops that pounce like tigers when you open Blender.
---

## Autostart Troubleshooting (Tray not loading at login)

If the tray does not appear automatically after reboot or login, it usually means
your **user systemd instance** is not fully active when the desktop starts.
Follow these steps once to make it persistent:

```bash
# Enable user lingering (ensures your user services start at login)
sudo loginctl enable-linger "$USER"

# Make sure the graphical session target exists
systemctl --user enable --now graphical-session.target

# Reload and enable the Smart Power services
systemctl --user daemon-reload
systemctl --user enable --now smart-power-daemon.service smart-power-tray.service
```

If your desktop still loads too quickly and the tray starts before a valid
display environment exists, add a small delay:

```bash
systemctl --user edit smart-power-tray.service
```
Add:
```
[Service]
ExecStartPre=/bin/sleep 10
```

Then reload and restart:
```bash
systemctl --user daemon-reload
systemctl --user restart smart-power-tray.service
```

You can also add a standard GNOME autostart entry as a fallback:

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/smart-power-tray.desktop <<'EOF'
[Desktop Entry]
Type=Application
Exec=/home/$USER/bin/powerprofile-tray.py
Hidden=false
X-GNOME-Autostart-enabled=true
Name=Smart Power Tray
Comment=Power profile indicator
EOF
```

After reboot, verify:
```bash
systemctl --user status smart-power-tray.service
journalctl --user -u smart-power-tray.service -b --no-pager | tail -20
```

Once configured, the tray will appear automatically after each login,
with both services (`smart-power-daemon` and `smart-power-tray`)
running continuously in your session.
