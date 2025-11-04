#!/usr/bin/env bash
# Smart Power Profiles — robust debug snapshot (ppd + powertop + cpupower)

set -euo pipefail

title() { printf "\n=== %s ===\n" "$1"; }
kv()    { printf "%-30s %s\n" "$1" "${2:-}"; }
yn()    { [[ "$1" -eq 1 ]] && echo yes || echo no; }

CACHE_DIR="${HOME}/.cache"
STATE_FILE="$CACHE_DIR/powerprofile.state"
LAST_FILE="$CACHE_DIR/powerprofile.last"
OVERRIDE_FILE="$CACHE_DIR/powerprofile.override"
SILENT_FILE="$CACHE_DIR/powerprofile.silent"
POWERTOP_LAST="$CACHE_DIR/powertop.last"

# --- 1) Environment ---------------------------------------------------------
title "Environment"
kv "Date/Time"               "$(date -Is)"
kv "Hostname"                "$(hostname)"
kv "Kernel"                  "$(uname -srmo)"
kv "User"                    "$USER"
kv "Shell"                   "$SHELL"
kv "XDG_RUNTIME_DIR"         "${XDG_RUNTIME_DIR:-<unset>}"
kv "Desktop session"         "${XDG_CURRENT_DESKTOP:-<unset>} / ${DESKTOP_SESSION:-<unset>}"

# --- 2) Commands available ---------------------------------------------------
title "Commands available"
cmds=(powerprofilesctl sensors nvidia-smi powertop notify-send bc cpupower systemctl journalctl)
for c in "${cmds[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then
    kv "$c" "$(command -v "$c")"
  else
    kv "$c" "not found"
  fi
done

# --- 3) Sudo NOPASSWD checks (no PAM spam; read sudoers only) ---------------
title "NOPASSWD rules (sudoers scan)"
check_nopasswd() {
  local cmd="$1" f
  for f in /etc/sudoers /etc/sudoers.d/*; do
    [[ -r "$f" ]] || continue
    if grep -qE "^[[:space:]]*${USER}[[:space:]]+ALL=.*NOPASSWD.*\b${cmd}\b" "$f"; then
      echo "yes ($f)"
      return
    fi
  done
  echo "no"
}
kv "powertop NOPASSWD"  "$(check_nopasswd powertop)"
kv "cpupower NOPASSWD"  "$(check_nopasswd cpupower)"

# --- 4) Power-profiles-daemon state -----------------------------------------
title "Power profile state (powerprofilesctl)"
if command -v powerprofilesctl >/dev/null 2>&1; then
  kv "Current profile" "$(powerprofilesctl get 2>/dev/null || echo '?')"
  kv "Available"       "$(powerprofilesctl list 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
else
  echo "powerprofilesctl not available."
fi

# --- 5) Smart Power state files ---------------------------------------------
title "Smart Power cache files"
kv "~/.cache exists"       "$( [[ -d "$CACHE_DIR" ]] && echo yes || echo no )"
kv "state file"            "$( [[ -f "$STATE_FILE" ]] && echo present || echo missing )"
kv "last file"             "$( [[ -f "$LAST_FILE"  ]] && echo present || echo missing )"
kv "override file"         "$( [[ -f "$OVERRIDE_FILE" ]] && echo present || echo absent )"
kv "silent file"           "$( [[ -f "$SILENT_FILE"   ]] && echo present || echo absent )"

[[ -f "$STATE_FILE"    ]] && kv "state value"    "$(tr -d '\n' < "$STATE_FILE")"
[[ -f "$LAST_FILE"     ]] && kv "last value"     "$(tr -d '\n' < "$LAST_FILE")"
[[ -f "$OVERRIDE_FILE" ]] && kv "override value" "$(tr -d '\n' < "$OVERRIDE_FILE")"

# --- 6) CPU snapshot ---------------------------------------------------------
title "CPU snapshot"
kv "Load (1m avg)" "$(awk '{print $1}' /proc/loadavg)"

# Package temperature (best effort)
CPU_TEMP="N/A"
if command -v sensors >/dev/null 2>&1; then
  CPU_TEMP=$(sensors 2>/dev/null | awk '
    /Package id 0:/ {gsub("\\+|°C",""); print int($4); found=1}
    END{ if(!found) print "" }')
fi
if [[ -z "${CPU_TEMP}" || "${CPU_TEMP}" == "N/A" ]]; then
  for f in /sys/class/thermal/thermal_zone*/temp /sys/devices/platform/coretemp.*/hwmon/hwmon*/temp1_input; do
    [[ -r "$f" ]] || continue
    v=$(cat "$f" 2>/dev/null || true)
    [[ -z "$v" ]] && continue
    if [[ "$v" -gt 1000 ]]; then CPU_TEMP=$(( v/1000 )); else CPU_TEMP="$v"; fi
    break
  done
fi
kv "Package temp (°C)" "${CPU_TEMP:-N/A}"

# Governors across CPUs
if ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1; then
  GOVS=$(awk '{print $0}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u | tr '\n' ' ')
  kv "Scaling governors" "${GOVS:-unknown}"
else
  kv "Scaling governors" "no cpufreq sysfs"
fi

# --- 7) GPU snapshot ---------------------------------------------------------
title "GPU detection"
HAS_NVIDIA=0
HAS_AMD=0
command -v nvidia-smi >/dev/null 2>&1 && HAS_NVIDIA=1
for vpath in /sys/class/drm/card*/device/vendor; do
  [[ -r "$vpath" ]] || continue
  if [[ "$(cat "$vpath" 2>/dev/null)" == "0x1002" ]]; then HAS_AMD=1; break; fi
done
kv "NVIDIA present" "$(yn "$HAS_NVIDIA")"
kv "AMD present"     "$(yn "$HAS_AMD")"

title "GPU utilization"
if [[ $HAS_NVIDIA -eq 1 ]]; then
  nv_vals=$(nvidia-smi --query-gpu=name,pci.bus_id,utilization.gpu,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)
  if [[ -n "$nv_vals" ]]; then
    echo "$nv_vals" | while IFS=, read -r name bus util temp; do
      kv "NV $bus util (%)" "$(echo "$util" | xargs)"
      kv "NV $bus temp (°C)" "$(echo "$temp" | xargs)"
      kv "NV $bus name" "$(echo "$name" | xargs)"
    done
  else
    echo "nvidia-smi returned no data."
  fi
else
  echo "No NVIDIA GPU detected."
fi

if [[ $HAS_AMD -eq 1 ]]; then
  any=0
  for card in /sys/class/drm/card*; do
    [[ -e "$card/device/vendor" ]] || continue
    vend=$(cat "$card/device/vendor" 2>/dev/null || echo)
    [[ "$vend" == "0x1002" ]] || continue
    any=1
    bus=$(basename "$card")
    util_path="$card/device/gpu_busy_percent"
    temp="N/A"
    for t in "$card"/hwmon/hwmon*/temp1_input; do
      [[ -r "$t" ]] || continue
      val=$(cat "$t" 2>/dev/null || true)
      [[ -n "$val" ]] && { [[ "$val" -gt 1000 ]] && temp=$(( val/1000 )) || temp="$val"; break; }
    done
    if [[ -r "$util_path" ]]; then
      util=$(tr -dc '0-9' < "$util_path")
      kv "AMD ${bus} util (%)" "${util:-N/A}"
      kv "AMD ${bus} temp (°C)" "$temp"
    else
      kv "AMD ${bus} util (%)" "gpu_busy_percent not found"
      kv "AMD ${bus} temp (°C)" "$temp"
    fi
  done
  [[ $any -eq 0 ]] && echo "No amdgpu nodes with counters found."
else
  echo "No AMD GPU detected."
fi

# --- 8) User services --------------------------------------------------------
title "Services (systemd --user)"
if systemctl --user show-environment >/dev/null 2>&1; then
  for svc in smart-power-daemon.service smart-power-tray.service; do
    if systemctl --user --quiet is-active "$svc"; then
      kv "$svc" "active"
    else
      kv "$svc" "inactive"
    fi
  done
  echo
  kv "daemon unit file" "$( [[ -f "$HOME/.config/systemd/user/smart-power-daemon.service" ]] && echo present || echo missing )"
  kv "tray unit file"   "$( [[ -f "$HOME/.config/systemd/user/smart-power-tray.service"   ]] && echo present || echo missing )"
  echo
  echo "daemon ExecStart:"
  systemctl --user cat smart-power-daemon.service 2>/dev/null | awk '/^\[Service\]/,0' | sed 's/^/  /' || true
else
  echo "User systemd not detected in this shell. Run inside your desktop session."
fi

# --- 9) Powertop cadence -----------------------------------------------------
title "Powertop status"
if command -v powertop >/dev/null 2>&1; then
  kv "powertop" "installed ($(powertop --version 2>/dev/null | head -n1))"
else
  kv "powertop" "not installed"
fi
kv "powertop.last file" "$( [[ -f "$POWERTOP_LAST" ]] && echo present || echo missing )"
if [[ -f "$POWERTOP_LAST" ]]; then
  sed 's/^/  /' "$POWERTOP_LAST"
fi

echo
echo "Recent powertop journal entries (tag=smart-power-powertop):"
journalctl --user -t smart-power-powertop -n 20 --no-pager 2>/dev/null || true

# --- 10) ppd “intel_pstate busy” errors (last 50 lines) ----------------------
title "Recent ppd errors (intel_pstate busy)"
journalctl --user -u smart-power-daemon.service -n 200 --no-pager 2>/dev/null | \
  grep -E "Failed to activate CPU driver 'intel_pstate'|Device or resource busy" || \
  echo "No recent 'intel_pstate busy' lines found in the last 200 daemon logs."

# --- 11) Quick sanity checks -------------------------------------------------
title "Quick sanity checks"
CUR=$(command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl get 2>/dev/null || echo "unknown")
LAST=$( [[ -f "$LAST_FILE" ]] && cat "$LAST_FILE" || echo "<none>" )
STATE=$( [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "<none>" )
OVR=$( [[ -f "$OVERRIDE_FILE" ]] && cat "$OVERRIDE_FILE" || echo "<none>" )
kv "ppd says current"   "$CUR"
kv "daemon last target" "$LAST"
kv "daemon state file"  "$STATE"
kv "override request"   "$OVR"

# Powertop cooldown inference
if [[ -f "$POWERTOP_LAST" ]]; then
  LAST_TS=$(grep -E '^ts=' "$POWERTOP_LAST" | sed 's/^ts=//' || true)
  NOW_TS=$(date +%s)
  if [[ -n "${LAST_TS:-}" ]]; then
    AGE=$(( NOW_TS - LAST_TS ))
    kv "seconds since powertop" "$AGE"
  fi
fi

title "Done"
