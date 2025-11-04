#!/usr/bin/env bash
# Smart Power Profile Manager for Ubuntu 25.10
# Dynamically switches between power-saver, balanced, and performance profiles.
# Integrates with powerprofilesctl and powertop for tuning, but skips USB autosuspend
# to prevent audio or input dropouts (e.g. DACs, mice, keyboards).

CHECK_INTERVAL=5
POWERTOP_ON_POWERSAVER=1

# Notification control:
# 1 = show notifications
# 0 = disable notifications permanently
# Create ~/.cache/powerprofile.silent to mute temporarily
NOTIFY=0
SILENT_FILE="$HOME/.cache/powerprofile.silent"

OVERRIDE_FILE="$HOME/.cache/powerprofile.override"
STATE_FILE="$HOME/.cache/powerprofile.state"

# --- Thresholds ---
# "Enter" thresholds (go up)
LOAD_BALANCED_UP=1.5
LOAD_PERF_UP=4.0
TEMP_BALANCED_UP=55
TEMP_PERF_UP=70
GPU_UTIL_BALANCED_UP=20
GPU_UTIL_PERF_UP=40
GPU_PWR_PERF_UP=90

# "Exit" thresholds (go down)
LOAD_BALANCED_DOWN=1.0
LOAD_PERF_DOWN=2.5
TEMP_BALANCED_DOWN=45
TEMP_PERF_DOWN=60
GPU_UTIL_BALANCED_DOWN=10
GPU_UTIL_PERF_DOWN=25
GPU_PWR_PERF_DOWN=60

FORCE_PERF_PROCS="steam|obs|resolve|blender|davinci|gamescope|proton"

mkdir -p "$(dirname "$STATE_FILE")"
have_nvidia=0
command -v nvidia-smi >/dev/null && have_nvidia=1
last_target=""

# ---------------------------------------------------------------------
# Helper: notifications
# ---------------------------------------------------------------------
notify() {
  # Skip notifications if disabled or silent mode active
  if (( !NOTIFY )) || [[ -f "$SILENT_FILE" ]]; then
    return
  fi
  command -v notify-send >/dev/null || return
  notify-send "Power Profile" "$1"
}

# ---------------------------------------------------------------------
# Helper: safe PowerTOP tuning (skip USB autosuspend)
# ---------------------------------------------------------------------
safe_powertune() {
  echo "Running PowerTOP (skip USB autosuspend completely)" >&2

  # Generate a temporary copy of powertop tunables without USB entries
  TMPFILE=$(mktemp)
  sudo powertop --auto-tune --explain >"$TMPFILE" 2>/dev/null || true

  # Manually apply only non-USB tunables
  while IFS= read -r line; do
    if [[ "$line" == *"/sys/bus/usb/"* ]]; then
      continue
    fi
    if [[ "$line" == *"/sys/"*"/power/"* ]]; then
      setting=$(echo "$line" | awk '{print $NF}')
      [[ -f "$setting" ]] && echo auto | sudo tee "$setting" >/dev/null 2>&1
    fi
  done <"$TMPFILE"

  rm -f "$TMPFILE"

  # Finally, ensure all USB devices stay awake
  for devpath in /sys/bus/usb/devices/*; do
    if [ -f "$devpath/power/control" ]; then
      echo on | sudo tee "$devpath/power/control" >/dev/null
    fi
  done
}


# ---------------------------------------------------------------------
# Helper: set power profile
# ---------------------------------------------------------------------
set_profile() {
  local target="$1"
  local current
  current=$(powerprofilesctl get)
  [[ "$current" == "$target" ]] && return
  powerprofilesctl set "$target"

  case "$target" in
    power-saver)
      ((POWERTOP_ON_POWERSAVER)) && safe_powertune
      ((NOTIFY)) && [[ ! -f "$SILENT_FILE" ]] && notify "🌙 Quiet mode (power-saver)"
      ;;
    balanced)
      ((NOTIFY)) && [[ ! -f "$SILENT_FILE" ]] && notify "⚙️ Balanced mode"
      ;;
    performance)
      ((NOTIFY)) && [[ ! -f "$SILENT_FILE" ]] && notify "⚡ Performance mode"
      ;;
  esac

  echo "$target" > "$STATE_FILE"
}


# ---------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------
while true; do
  # Manual override
  if [[ -f "$OVERRIDE_FILE" ]]; then
    override=$(<"$OVERRIDE_FILE")
    [[ -n "$override" ]] && set_profile "$override"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  load=$(awk '{print $1}' /proc/loadavg)
  temp=$(sensors 2>/dev/null | awk '/Package id 0:/ {gsub("\\+|°C",""); print int($4)}' | head -n1)
  [[ -z "$temp" ]] && temp=0

  gpu_util=0; gpu_pwr=0
  if (( have_nvidia )); then
    line=$(nvidia-smi --query-gpu=utilization.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n1)
    gpu_util=$(awk -F',' '{gsub(" ",""); print $1+0}' <<<"$line")
    gpu_pwr=$(awk -F',' '{gsub(" ",""); print $2+0}' <<<"$line")
  fi

  force_perf=0
  if pgrep -falE "$FORCE_PERF_PROCS" >/dev/null 2>&1; then
    force_perf=1
  fi

  target="$last_target"

  case "$last_target" in
    power-saver)
      if (( force_perf==1 )) ||
         (( $(echo "$load > $LOAD_PERF_UP" | bc -l) )) ||
         (( $(echo "$temp > $TEMP_PERF_UP" | bc -l) )) ||
         (( $(echo "$gpu_util > $GPU_UTIL_PERF_UP" | bc -l) )) ||
         (( $(echo "$gpu_pwr > $GPU_PWR_PERF_UP" | bc -l) )); then
        target="performance"
      elif (( $(echo "$load > $LOAD_BALANCED_UP" | bc -l) )) ||
           (( $(echo "$temp > $TEMP_BALANCED_UP" | bc -l) )) ||
           (( $(echo "$gpu_util > $GPU_UTIL_BALANCED_UP" | bc -l) )); then
        target="balanced"
      fi
      ;;
    balanced)
      if (( force_perf==1 )) ||
         (( $(echo "$load > $LOAD_PERF_UP" | bc -l) )) ||
         (( $(echo "$temp > $TEMP_PERF_UP" | bc -l) )) ||
         (( $(echo "$gpu_util > $GPU_UTIL_PERF_UP" | bc -l) )) ||
         (( $(echo "$gpu_pwr > $GPU_PWR_PERF_UP" | bc -l) )); then
        target="performance"
      elif (( $(echo "$load < $LOAD_BALANCED_DOWN" | bc -l) )) &&
           (( $(echo "$temp < $TEMP_BALANCED_DOWN" | bc -l) )) &&
           (( $(echo "$gpu_util < $GPU_UTIL_BALANCED_DOWN" | bc -l) )); then
        target="power-saver"
      fi
      ;;
    performance)
      if (( $(echo "$load < $LOAD_PERF_DOWN" | bc -l) )) &&
         (( $(echo "$temp < $TEMP_PERF_DOWN" | bc -l) )) &&
         (( $(echo "$gpu_util < $GPU_UTIL_PERF_DOWN" | bc -l) )) &&
         (( $(echo "$gpu_pwr < $GPU_PWR_PERF_DOWN" | bc -l) )); then
        target="balanced"
      fi
      ;;
    *)
      target="power-saver"
      ;;
  esac

  if [[ "$target" != "$last_target" ]]; then
    last_target="$target"
    set_profile "$target"
  fi

  sleep "$CHECK_INTERVAL"
done
