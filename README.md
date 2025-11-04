# Smart Power Profiles

Smart Power Profiles automatically switches between **power-saver**, **balanced**, and **performance** on Ubuntu 25.10 based on live **CPU load, temps, GPU activity, and active apps**. It also ships a lightweight tray so you can click to change modes or temporarily override “Auto”.

The daemon is **systemd --user** friendly, safe by default, and tuned to avoid common Linux pitfalls like **USB autosuspend breaking DACs/keyboards**.

---

## ✨ Features

- **Auto switching** between power-saver / balanced / performance
- **Hysteresis**: different enter/exit thresholds to prevent flapping
- **Fast bump** to Performance for heavy load or when apps like Steam/OBS are running
- Optional **Powertop integration** when entering power-saver
  - Implemented in **USB‑safe** mode (skips USB autosuspend entirely)
- **Tray indicator** with emoji status: 🌙 ⚙️ ⚡ and an **Auto** option
- **Manual override** via tray or file (and auto-resume)
- **Quiet mode** (no notifications) with a single flag file
- Robust **systemd --user** services for both daemon + tray

---

## 🧩 Requirements

- Ubuntu 25.10 (GNOME / Wayland works fine)
- Packages: `powerprofilesctl` (built-in via power-profiles-daemon), `powertop` (optional), `lm-sensors`, `nvidia-smi` (optional, NVIDIA)
- AppIndicator host (Ubuntu enables by default)

> NVIDIA is optional. If `nvidia-smi` is unavailable, GPU checks are skipped.

---

## 🚀 Install / Update

Clone and install (safe to re-run for updates):

```bash
git clone https://github.com/shiny-sand/smart-power-profiles.git
cd smart-power-profiles
./install.sh
```

Installer does:
- Copies scripts into `~/bin/`
- Creates/updates **systemd --user** units
- Enables and starts both services

Manage services:

```bash
systemctl --user status smart-power-daemon.service
systemctl --user status smart-power-tray.service

systemctl --user restart smart-power-daemon.service smart-power-tray.service
```

> If you previously had a `.desktop` autostart for the tray, you can remove:
> `~/.config/autostart/powerprofile-tray.desktop` and `~/.local/share/applications/powerprofile-tray.desktop`.

---

## ⚙️ How it works (and what to tweak)

The daemon reads system state every few seconds and decides a target profile:

- **Enter thresholds** (to go up):
  - `LOAD_BALANCED_UP=1.5`, `LOAD_PERF_UP=4.0`
  - `TEMP_BALANCED_UP=55`, `TEMP_PERF_UP=70` (°C, CPU package)
  - `GPU_UTIL_BALANCED_UP=20`, `GPU_UTIL_PERF_UP=40` (%)
  - `GPU_PWR_PERF_UP=90` (W, NVIDIA)
- **Exit thresholds** (to go down):
  - `LOAD_BALANCED_DOWN=1.0`, `LOAD_PERF_DOWN=2.5`
  - `TEMP_BALANCED_DOWN=45`, `TEMP_PERF_DOWN=60`
  - `GPU_UTIL_BALANCED_DOWN=10`, `GPU_UTIL_PERF_DOWN=25`
  - `GPU_PWR_PERF_DOWN=60`

Processes that **force Performance** if detected:
```
steam|obs|resolve|blender|davinci|gamescope|proton
```

You can tune any of these at the top of `~/bin/auto-powerprofile.sh` and then:

```bash
systemctl --user restart smart-power-daemon.service
```

---

## 🔕 Notifications & Silent Mode

- By default, notifications are **off** in the daemon (`NOTIFY=0` inside the script).
- You can **temporarily** silence both daemon and tray by creating a flag file:
  ```bash
  touch ~/.cache/powerprofile.silent
  # remove to re-enable
  rm ~/.cache/powerprofile.silent
  ```
- If you want the tray to **never** notify, the installer supports an env flag in the tray unit:
  ```ini
  # ~/.config/systemd/user/smart-power-tray.service
  [Service]
  Environment=POWERPROFILE_NOTIFY=0
  ```
  Then:
  ```bash
  systemctl --user daemon-reload
  systemctl --user restart smart-power-tray.service
  ```

---

## 🔌 Powertop (USB‑safe)

When entering **power-saver**, Smart Power Profiles can apply Powertop tunables to save extra watts. To prevent common issues with **USB DACs, keyboards, mice, webcams**, we **skip USB autosuspend entirely**. CPU/PCIe/SATA tunables are still applied.

This avoids kernel spam like:
```
usb_set_interface failed (-110)
```

Powertop is **optional**. You can toggle it inside `~/bin/auto-powerprofile.sh`:

```bash
POWERTOP_ON_POWERSAVER=1   # enable (default)
# POWERTOP_ON_POWERSAVER=0 # disable
```

### Allowing Powertop without password (optional)
`powertop` needs sudo. As a user service, there’s no password prompt. Grant **passwordless sudo for powertop only**:

```bash
sudo visudo -f /etc/sudoers.d/powertop-nopasswd
```
Add this line (replace `<your_username>`):
```
<your_username> ALL=(ALL) NOPASSWD: /usr/bin/powertop
```

If you prefer **not** to change sudoers, set `POWERTOP_ON_POWERSAVER=0`.

---

## 🖱️ Tray

The tray shows the current mode via emoji:
- 🌙 **power-saver**
- ⚙️ **balanced**
- ⚡ **performance**

Menu options:
- Pick a mode to **override** the daemon
- Choose **Auto (remove override)** to return control to the daemon

Under the hood it writes/reads:
```
~/.cache/powerprofile.override
~/.cache/powerprofile.state
```

---

## 🧪 Debugging

Quick snapshot:
```bash
~/Projects/smart-power-profiles/bin/debug-powerprofile.sh
```

Check services and logs:
```bash
systemctl --user status smart-power-daemon.service
systemctl --user status smart-power-tray.service

journalctl --user -u smart-power-daemon.service -b --no-pager
journalctl --user -u smart-power-tray.service -b --no-pager
```

Verify USB autosuspend is **off**:
```bash
grep . /sys/bus/usb/devices/*/power/control | cut -d: -f2- | sort -u
# should print only: on
```

Seeing repeated `usb_set_interface failed (-110)`? That’s a USB device failing to wake from suspend. The script already avoids suspending USB, but if you customized anything or run other tuners, ensure all USB `power/control` files are `on`.

---

## 🧽 Uninstall

```bash
./uninstall.sh
```

What it does:
- Disables & stops the **systemd --user** services
- Removes their unit files from `~/.config/systemd/user/`
- Leaves your `~/bin/` scripts in place (so you can keep or manually remove them)

Manual cleanup (optional):
```bash
rm -f ~/bin/auto-powerprofile.sh ~/bin/powerprofile-tray.py
systemctl --user daemon-reload
```

---

## 🔐 Security notes

- The optional sudo rule is **limited to `powertop` only**:
  ```
  <your_username> ALL=(ALL) NOPASSWD: /usr/bin/powertop
  ```
- If you’re not comfortable with that, set `POWERTOP_ON_POWERSAVER=0`.
- The daemon and tray run as your **regular user** under `systemd --user`; they do not require admin privileges otherwise.

---

## 🪪 License

MIT © 2025 shiny-sand