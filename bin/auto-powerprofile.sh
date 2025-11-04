#!/usr/bin/env bash
# Smart Power Profile Manager (load-only, no powertop)
# Decides between power-saver / balanced / performance using powerprofilesctl.
# Short retries to dodge "busy". Keeps ~/.cache state for the tray.
# Manual override via ~/.cache/powerprofile.override

set -euo pipefail

# ===== Settings =====
CHECK_INTERVAL=5

# p-p-d set retry
PPD_SET_RETRIES=3
PPD_SET_RETRY_SLEEP=1

# Notifications
NOTIFY=1
CACHE_DIR="$HOME/.cache"
SILENT_FILE="$CACHE_DIR/powerprofile.silent"

# State files (tray compatibility)
STATE_FILE="$CACHE_DIR/powerprofile.state"       # last applied profile (real)
LAST_APPLIED_FILE="$CACHE_DIR/powerprofile.last" # last target we attempted
OVERRIDE_FILE="$CACHE_DIR/powerprofile.override" # manual override target

mkdir -p "$CACHE_DIR"

# ===== Thresholds (hysteresis) =====
# Load uses 1-minute average from /proc/loadavg.
LOAD_PERF_ENTER=8.0; LOAD_PERF_EXIT=5.0
LOAD_BAL_ENTER=2.5;  LOAD_BAL_EXIT=1.0

# Optional GPU awareness. Off by default.
GPU_AWARE=0
GPU_PERF_ENTER=70
GPU_PERF_EXIT=50
GPU_BAL_ENTER=25
GPU_BAL_EXIT=10

# Optional temperature awareness. Off by default.
TEMP_AWARE=0
TEMP_PERF_ENTER=80
TEMP_PERF_EXIT=70
TEMP_BAL_ENTER=60
TEMP_BAL_EXIT=45

# ===== Helpers =====
notify() {
  [[ $NOTIFY -eq 1 ]] || return 0
  [[ -f "$SILENT_FILE" ]] && return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  # $2 is optional
  if [[ -n "${2-}" ]]; then
    notify-send -a "Smart Power Profiles" "$1" "$2" || true
  else
    notify-send -a "Smart Power Profiles" "$1" || true
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[auto-powerprofile] Missing required command: $1" >&2
    exit 1
  }
}

# Numeric compare using bc; fallback to awk if bc missing
num_lt() {
  if command -v bc >/dev/null 2>&1; then
    [[ $(echo "$1 < $2" | bc -l) -eq 1 ]]
  else
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'
  fi
}
num_ge() {
  if command -v bc >/dev/null 2>&1; then
    [[ $(echo "$1 >= $2" | bc -l) -eq 1 ]]
  else
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'
  fi
}

read_cpu_load() { awk '{print $1}' /proc/loadavg; }

read_cpu_temp() {
  [[ $TEMP_AWARE -eq 1 ]] || { echo 0; return; }
  local t=""
  if command -v sensors >/dev/null 2>&1; then
    # Typical line: "Package id 0:  +55.0°C  (high = ...)"
    t=$(sensors 2>/dev/null | awk '/Package id 0:/ {gsub(/\+|°C/,"",$4); print int($4)}' | head -n1)
  fi
  [[ -z "${t:-}" ]] && t=0
  echo "$t"
}

have_nvidia=0
command -v nvidia-smi >/dev/null 2>&1 && have_nvidia=1

read_gpu_util() {
  [[ $GPU_AWARE -eq 1 ]] || { echo 0; return; }
  local max_util=0 nutil
  if (( have_nvidia )); then
    while IFS= read -r nutil; do
      [[ "$nutil" =~ ^[0-9]+$ ]] || continue
      (( nutil > max_util )) && max_util=$nutil
    done < <(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || true)
  fi
  echo "${max_util:-0}"
}

ppd_get() {
  powerprofilesctl get 2>/dev/null || echo balanced
}

ppd_set_retry() {
  local target="$1"
  local i out
  for ((i=1; i<=PPD_SET_RETRIES; i++)); do
    out=""
    if out=$(powerprofilesctl set "$target" 2>&1); then
      return 0
    fi
    # Busy happens sometimes with intel_pstate
    if grep -qiE "busy|Failed to activate CPU driver" <<<"$out"; then
      sleep "$PPD_SET_RETRY_SLEEP"
      continue
    fi
    # Other error. Try again briefly anyway.
    sleep "$PPD_SET_RETRY_SLEEP"
  done
  return 1
}

# ===== Decision logic =====
decide_profile() {
  local load="$1" temp="$2" gpu="$3"
  local current; current="$(ppd_get)"

  # Manual override wins
  if [[ -f "$OVERRIDE_FILE" ]]; then
    local o; o=$(<"$OVERRIDE_FILE")
    [[ -n "$o" ]] && { echo "$o"; return; }
  fi

  # Useful flags so temp/gpu can be disabled cleanly
  local hot=0 cool=1 busy_gpu=0 idle_gpu=1
  if [[ $TEMP_AWARE -eq 1 ]]; then
    (( temp >= TEMP_PERF_ENTER )) && hot=1
    if (( temp < TEMP_PERF_EXIT )); then cool=1; else cool=0; fi
  fi
  if [[ $GPU_AWARE -eq 1 ]]; then
    (( gpu >= GPU_PERF_ENTER )) && busy_gpu=1
    if (( gpu < GPU_PERF_EXIT )); then idle_gpu=1; else idle_gpu=0; fi
  fi

  case "$current" in
    performance)
      if $(num_lt "$load" "$LOAD_PERF_EXIT") && (( cool == 1 )) && (( idle_gpu == 1 )); then
        if $(num_lt "$load" "$LOAD_BAL_EXIT") && (( (TEMP_AWARE==0) || (temp < TEMP_BAL_EXIT) )) && (( (GPU_AWARE==0) || (gpu < GPU_BAL_EXIT) )); then
          echo "power-saver"
        else
          echo "balanced"
        fi
      else
        echo "performance"
      fi
      ;;
    balanced)
      if $(num_ge "$load" "$LOAD_PERF_ENTER") || (( hot == 1 )) || (( busy_gpu == 1 )); then
        echo "performance"
      elif $(num_lt "$load" "$LOAD_BAL_EXIT") && (( (TEMP_AWARE==0) || (temp < TEMP_BAL_EXIT) )) && (( (GPU_AWARE==0) || (gpu < GPU_BAL_EXIT) )); then
        echo "power-saver"
      else
        echo "balanced"
      fi
      ;;
    power-saver|*)
      if $(num_ge "$load" "$LOAD_PERF_ENTER") || (( hot == 1 )) || (( busy_gpu == 1 )); then
        echo "performance"
      elif $(num_ge "$load" "$LOAD_BAL_ENTER") || (( (TEMP_AWARE==1) && (temp >= TEMP_BAL_ENTER) )) || (( (GPU_AWARE==1) && (gpu >= GPU_BAL_ENTER) )); then
        echo "balanced"
      else
        echo "power-saver"
      fi
      ;;
  esac
}

# ===== Apply and record =====
apply_profile() {
  local target="$1"
  local last_target=""
  [[ -r "$LAST_APPLIED_FILE" ]] && last_target=$(<"$LAST_APPLIED_FILE")

  local before; before="$(ppd_get)"
  if [[ "$before" != "$target" ]]; then
    ppd_set_retry "$target" || true
  fi

  # Read back the real state and record that for the tray
  local actual; actual="$(ppd_get)"

  # Only notify when the effective profile changed
  if [[ "$actual" != "$before" ]]; then
    case "$actual" in
      power-saver) notify "Power Saver" "Lower clocks, quieter." ;;
      balanced)    notify "Balanced" "General purpose." ;;
      performance) notify "Performance" "Higher clocks for heavy load." ;;
    esac
  fi

  # Update files: last target we tried, and the actual current profile
  if [[ "$last_target" != "$target" ]]; then
    echo "$target" > "$LAST_APPLIED_FILE" || true
  fi
  echo "$actual" > "$STATE_FILE" || true
}

# ===== Preflight =====
preflight() {
  need_cmd powerprofilesctl
  # Optional tools are checked lazily: bc, sensors, nvidia-smi, notify-send
}

# ===== Main loop =====
main_loop() {
  : > "$STATE_FILE" || true
  while true; do
    load="$(read_cpu_load)"
    temp="$(read_cpu_temp)"
    gpu="$(read_gpu_util)"
    target="$(decide_profile "$load" "$temp" "$gpu")"
    apply_profile "$target"
    sleep "$CHECK_INTERVAL"
  done
}

preflight
main_loop
