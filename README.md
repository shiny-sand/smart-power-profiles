# Smart Power Profiles (Ubuntu 25.10+)

Smart Power Profiles auto-switches between **power-saver**, **balanced**, and **performance** based on live **CPU load**, **CPU temps**, and **GPU activity**. It runs as a **systemd --user** daemon with a tiny tray app for quick overrides.

This project is designed to be **clone → install → go** for the average GitHub user. No root daemons. Sensible defaults. Safe fallbacks. Optional Powertop tuning.

---

## ✨ Highlights

- **Auto switching** with hysteresis to avoid flapping
- **GPU aware**: NVIDIA via `nvidia-smi`, AMD via `gpu_busy_percent`
- **Heavy-app fast path** (Steam/OBS/Blender etc. bump to performance)
- **Optional Powertop** when entering power‑saver (USB‑safe)
- **Tray indicator (text-only)** that shows **A:** or **M:** and the active profile, e.g. `A: Balanced` or `M: Performance`
- **Manual override** via tray or a simple flag file
- **Notification silence** via a single flag file
- Clean **systemd --user** services; no PAM spam or password prompts

---

## 🧩 Requirements

- Ubuntu 25.10 (GNOME/Wayland tested)
- Packages (installer will pull them):  
  `python3-gi gir1.2-gtk-3.0 libnotify-bin power-profiles-daemon lm-sensors powertop bc`
- Optional:
  - NVIDIA: `nvidia-smi` (provided by the driver) for GPU util
  - `cpupower` (from `linux-tools-common` on Ubuntu) for governor hints

> If NVIDIA/AMD metrics aren’t available, the daemon still works using CPU load/temps.

---

## 🚀 Install / Update

```bash
git clone https://github.com/shiny-sand/smart-power-profiles.git
cd smart-power-profiles
./install.sh
```

The installer:
- Installs deps
- Copies scripts to `~/bin/`
- Creates **systemd --user** units
- Starts **daemon** and **tray**

It also **offers** (prompted) to create a **sudoers snippet** that allows passwordless `powertop` and `cpupower` for your user:
```
/etc/sudoers.d/smart-power
<your_user> ALL=(ALL) NOPASSWD: /usr/sbin/powertop, /usr/bin/cpupower
```
This is optional. If you skip it, the daemon simply **skips Powertop** instead of spamming PAM.

---

## 🖥️ Tray (text-only, compact)

The tray label shows:
- `A: <Profile>` when **Auto** is active
- `M: <Profile>` when **Manual override** is active

Examples:
- `A: Balanced`
- `M: Performance`
- `A: Power Saver`

Menu items:
- **Auto** (remove manual override)
- **Power Saver / Balanced / Performance** (manual pick)
- **Notifications** toggle
- **Appearance** (label/format, no icons)
- **Open Debug Snapshot**
- **Quit**

> The project intentionally avoids themed icons because they’re unreliable across themes and can render as `…` when a theme doesn’t ship the name. Text is robust and minimal.

---

## ⚙️ How it decides

The daemon samples every few seconds and chooses a target profile. It uses **hysteresis thresholds** and a **“heavy app” fast path** to jump straight to **performance** when certain processes are detected (Steam, OBS, Blender, DaVinci, etc.).

You can tune thresholds at the top of `~/bin/auto-powerprofile.sh`, then:

```bash
systemctl --user restart smart-power-daemon.service
```

---

## 🔌 Powertop integration (USB‑safe)

When entering **power-saver**, the daemon can run:

- `powertop --auto-tune` (if allowed without password)
- Then **keeps USB awake** (`power/control=on`) to avoid DAC/keyboard/mouse/webcam issues

It will **not** attempt to run Powertop unless the NOPASSWD rule exists (or you explicitly allowed it). This prevents **`pam_unix` spam** in the journal from password prompts that can’t be answered inside a user service.

You can verify Powertop ran with these markers/logs:
```bash
cat ~/.cache/powertop.last
journalctl --user -t smart-power-powertop -n 20 --no-pager
```

Force a one‑shot test:
```bash
rm -f ~/.cache/powertop.last
echo balanced > ~/.cache/powerprofile.last
echo power-saver > ~/.cache/powerprofile.override
sleep 8
cat ~/.cache/powertop.last
journalctl --user -t smart-power-powertop -n 20 --no-pager
rm -f ~/.cache/powerprofile.override
```

Disable Powertop entirely by setting in the script:
```bash
POWERTOP_ON_POWERSAVER=0
```

---

## 🔕 Notifications & overrides

- Silence notifications (daemon & tray) via a flag file:
  ```bash
  touch ~/.cache/powerprofile.silent
  # remove to re-enable
  rm ~/.cache/powerprofile.silent
  ```
- Manual override (without the tray):
  ```bash
  echo performance > ~/.cache/powerprofile.override   # lock to performance
  rm -f ~/.cache/powerprofile.override               # return to Auto
  ```

State files:
```
~/.cache/powerprofile.state        # last applied profile
~/.cache/powerprofile.override     # presence = manual mode
~/.cache/powertop.last             # last powertop run (if any)
```

---

## 🧪 Debugging

Quick system snapshot:
```bash
~/bin/debug-powerprofile.sh
```

Services and logs:
```bash
systemctl --user status smart-power-daemon.service
systemctl --user status smart-power-tray.service
journalctl --user -u smart-power-daemon.service -b --no-pager
journalctl --user -u smart-power-tray.service   -b --no-pager
```

Verify USB stays awake:
```bash
grep . /sys/bus/usb/devices/*/power/control | awk -F: '{print $2}' | sort -u
# should show only: on
```

If you ever see repeated `pam_unix(sudo:auth)` lines:
- You likely have an older version or another service calling `sudo -n` repeatedly
- Stop and disable any old units, then reload:
  ```bash
  systemctl --user disable --now smart-power-daemon.service smart-power-tray.service
  pkill -f auto-powerprofile.sh || true
  systemctl --user daemon-reload
  systemctl --user enable --now smart-power-daemon.service smart-power-tray.service
  ```

---

## 🧽 Uninstall

```bash
./uninstall.sh
```

This disables the services and removes their unit files. Your `~/bin/` scripts are left in place so you can keep or delete them.

Optional cleanup:
```bash
rm -f ~/bin/auto-powerprofile.sh ~/bin/powerprofile-tray.py ~/bin/debug-powerprofile.sh
systemctl --user daemon-reload
```

---

## 🔐 Security

- The optional sudo rule is limited to:
  ```
  <your_user> ALL=(ALL) NOPASSWD: /usr/sbin/powertop, /usr/bin/cpupower
  ```
- If you prefer not to change sudoers, the daemon simply **skips** Powertop.

---

## 🪪 License

MIT © 2025 shiny-sand