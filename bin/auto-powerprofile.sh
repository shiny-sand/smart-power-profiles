#!/usr/bin/env bash
# Auto + manual power profile manager for Ubuntu 25.10
# Requires: powerprofilesctl, nvidia-smi, sensors, bc

CHECK_INTERVAL=5
POWERTOP_ON_POWERSAVER=1
NOTIFY=1
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

notify() {
  ((NOTIFY)) || return
  command -v notify-send >/dev/null || return
  notify-send "Power Profile" "$1"
}

set_profile() {
  local target="$1"
  local current
  current=$(powerprofilesctl get)
  [[ "$current" == "$target" ]] && return
  powerprofilesctl set "$target"
  case "$target" in
    power-saver)
      ((POWERTOP_ON_POWERSAVER)) && sudo -n powertop --auto-tune >/dev/null 2>&1
      notify "🌙 Quiet mode (power-saver)"
      ;;
    balanced)
      notify "⚙️ Balanced mode"
      ;;
    performance)
      notify "⚡ Performance mode"
      ;;
  esac
  echo "$target" > "$STATE_FILE"
}

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
      # Jump up fast if we cross upper thresholds
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
      # Jump up if hitting performance trigger
      if (( force_perf==1 )) ||
         (( $(echo "$load > $LOAD_PERF_UP" | bc -l) )) ||
         (( $(echo "$temp > $TEMP_PERF_UP" | bc -l) )) ||
         (( $(echo "$gpu_util > $GPU_UTIL_PERF_UP" | bc -l) )) ||
         (( $(echo "$gpu_pwr > $GPU_PWR_PERF_UP" | bc -l) )); then
        target="performance"
      # Drop down only if all calm below lower balanced thresholds
      elif (( $(echo "$load < $LOAD_BALANCED_DOWN" | bc -l) )) &&
           (( $(echo "$temp < $TEMP_BALANCED_DOWN" | bc -l) )) &&
           (( $(echo "$gpu_util < $GPU_UTIL_BALANCED_DOWN" | bc -l) )); then
        target="power-saver"
      fi
      ;;
    performance)
      # Drop back only when well below performance thresholds
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
