#!/usr/bin/env bash
# Auto + manual power profile manager for Ubuntu 25.10
# Requires: powerprofilesctl, nvidia-smi, sensors, bc

CHECK_INTERVAL=10
DWELL_READS=3
POWERTOP_ON_POWERSAVER=1
NOTIFY=1
OVERRIDE_FILE="$HOME/.cache/powerprofile.override"
STATE_FILE="$HOME/.cache/powerprofile.state"

LOAD_BALANCED=1.0
LOAD_PERF=4.0
TEMP_BALANCED=50
TEMP_PERF=70
GPU_UTIL_BALANCED=15
GPU_UTIL_PERF=40
GPU_PWR_PERF=90
FORCE_PERF_PROCS="steam|obs|resolve|blender|davinci|gamescope|proton"

mkdir -p "$(dirname "$STATE_FILE")"
have_nvidia=0
command -v nvidia-smi >/dev/null && have_nvidia=1
last_target=""
need_reads=0

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
  # Manual override?
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

  target="power-saver"
  perf_cond=$(awk -v l="$load" -v t="$temp" -v gu="$gpu_util" -v gp="$gpu_pwr" \
    -v lp="$LOAD_PERF" -v tp="$TEMP_PERF" -v gup="$GPU_UTIL_PERF" -v gpp="$GPU_PWR_PERF" \
    'BEGIN{if (l>lp||t>tp||gu>gup||gp>gpp) print 1; else print 0}')
  bal_cond=$(awk -v l="$load" -v t="$temp" -v gu="$gpu_util" \
    -v lb="$LOAD_BALANCED" -v tb="$TEMP_BALANCED" -v gub="$GPU_UTIL_BALANCED" \
    'BEGIN{if (l>lb||t>tb||gu>gub) print 1; else print 0}')

  if (( force_perf==1 || perf_cond==1 )); then
    target="performance"
  elif (( bal_cond==1 )); then
    target="balanced"
  fi

  if [[ "$target" != "$last_target" ]]; then
    last_target="$target"
    need_reads=$DWELL_READS
  elif (( need_reads > 0 )); then
    need_reads=$((need_reads-1))
  else
    set_profile "$target"
  fi

  sleep "$CHECK_INTERVAL"
done
