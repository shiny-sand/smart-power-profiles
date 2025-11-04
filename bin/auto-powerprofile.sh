#!/usr/bin/env bash
# Smart Power Profile Manager (desktop-tuned)
# Goal: save power when idle/low load, but snap to full performance under medium/high load.
# Uses powerprofilesctl only (no powertop). Safe by default.
#
# Features:
# - Secure defaults (umask 077)
# - Single-instance guard (flock)
# - Desktop-biased thresholds + hysteresis
# - Spike accelerator for quick boosts
# - Optional GPU util + CPU/GPU temp awareness
# - GPU temp trigger with hwmon-first, nvidia-smi fallback (cached)
# - Debounced notifications
# - Sanitized manual override (~/.cache/powerprofile.override)

set -euo pipefail
umask 077

# ===== Settings =====
# Faster cadence for snappier reaction on desktops.
CHECK_INTERVAL=2

# Power Profiles Daemon set retry
PPD_SET_RETRIES=3
PPD_SET_RETRY_SLEEP=1

# Notifications
NOTIFY=1
CACHE_DIR="$HOME/.cache"
SILENT_FILE="$CACHE_DIR/powerprofile.silent"
LAST_NOTIFY_FILE="$CACHE_DIR/powerprofile.lastnotify"
NOTIFY_COOLDOWN=10

# State files (tray compatibility)
STATE_FILE="$CACHE_DIR/powerprofile.state"       # actual current profile (read back after apply)
LAST_APPLIED_FILE="$CACHE_DIR/powerprofile.last" # last target we attempted to set
OVERRIDE_FILE="$CACHE_DIR/powerprofile.override" # manual override target (validated)
LOCK_FILE="$CACHE_DIR/powerprofile.lock"

mkdir -p "$CACHE_DIR"

# ===== Thresholds (desktop-biased hysteresis) =====
# CPU load uses 1-minute average from /proc/loadavg.
LOAD_PERF_ENTER=4.0; LOAD_PERF_EXIT=2.5     # enter perf earlier, exit when decently calm
LOAD_BAL_ENTER=1.2;  LOAD_BAL_EXIT=0.5      # enter balanced above light work; exit when truly idle

# Spike accelerator:
# If short busy% approximates (LOAD_PERF_ENTER * 20 * SPIKE_ACCEL_FRACTION), jump to performance.
SPIKE_ACCEL_FRACTION=0.85
SPIKE_CPU_BUSY_PCT_BASE_MULT=20    # heuristic: 1.0 load ~ 20% busy on many multi-core desktops

# Optional GPU util awareness (off by default; enable = 1)
GPU_AWARE=0
GPU_PERF_ENTER=50
GPU_PERF_EXIT=35
GPU_BAL_ENTER=15
GPU_BAL_EXIT=5

# Optional CPU temperature awareness (protect from sustained heat). Off by default.
TEMP_AWARE=0
TEMP_PERF_ENTER=80
TEMP_PERF_EXIT=70
TEMP_BAL_ENTER=60
TEMP_BAL_EXIT=45

# GPU temperature trigger (on by default).
# If GPU temp >= GPU_TEMP_PERF_ENTER → force performance.
GPU_TEMP_AWARE=1
GPU_TEMP_PERF_ENTER=37

# Cache window for nvidia-smi temperature reads (seconds)
GPU_TEMP_CACHE_SEC=10
GPU_TEMP_CACHE_FILE="$CACHE_DIR/powerprofile.gputemp"

# ===== Helpers =====
notify() {
  [[ $NOTIFY -eq 1 ]] || return 0
  [[ -f "$SILENT_FILE" ]] && return 0
  command -v notify-send >/dev/null 2>&1 || return 0

  local now last=0
  now=$(date +%s)
  [[ -r "$LAST_NOTIFY_FILE" ]] && last=$(<"$LAST_NOTIFY_FILE")
  (( now - last < NOTIFY_COOLDOWN )) && return 0

  if [[ -n "${2-}" ]]; then
    notify-send -a "Smart Power Profiles" "$1" "$2" || true
  else
    notify-send -a "Smart Power Profiles" "$1" || true
  fi
  echo "$now" > "$LAST_NOTIFY_FILE" || true
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

# 1-minute load (smooth, conservative)
read_cpu_load() { awk '{print $1}' /proc/loadavg; }

# Short-interval CPU busy% from /proc/stat deltas
_prev_total=0 _prev_idle_all=0 _have_prev=0
read_cpu_short_busy_pct() {
  local cpu user nice system idle iowait irq softirq steal guest guest_nice
  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

  local idle_all=$((idle + iowait))
  local non_idle=$((user + nice + system + irq + softirq + steal))
  local total=$((idle_all + non_idle))

  if ((_have_prev==0)); then
    _prev_total=$total
    _prev_idle_all=$idle_all
    _have_prev=1
    echo 0
    return
  fi

  local d_total=$((total - _prev_total))
  local d_idle=$((idle_all - _prev_idle_all))
  _prev_total=$total
  _prev_idle_all=idle_all

  (( d_total <= 0 )) && { echo 0; return; }
  awk -v dt="$d_total" -v di="$d_idle" 'BEGIN{printf "%.0f", (dt - di) * 100.0 / dt}'
}

# ----- CPU temperature (optional) -----
read_cpu_temp_only() {
  local t=""
  if command -v sensors >/dev/null 2>&1; then
    t=$(sensors 2>/dev/null | awk '
      /Package id 0:|Tctl:|Tdie:/ {
        for (i=1;i<=NF;i++) if ($i ~ /\+?[0-9]+(\.[0-9]+)?°C/) {
          gsub(/\+|°C/, "", $i); printf "%d\n", $i; exit
        }
      }' | head -n1)
  fi
  if [[ -z "${t:-}" ]] && [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
    local raw; raw=$(< /sys/class/thermal/thermal_zone0/temp)
    [[ "$raw" =~ ^[0-9]+$ ]] && t=$(( raw/1000 ))
  fi
  echo "${t:-0}"
}

read_cpu_temp() {
  [[ $TEMP_AWARE -eq 1 ]] || { echo 0; return; }
  read_cpu_temp_only
}

# ----- GPU util (optional) -----
have_nvidia=0
command -v nvidia-smi >/dev/null 2>&1 && have_nvidia=1

have_amd=0
if [[ -n "$(find /sys/class/drm -type f -name gpu_busy_percent 2>/dev/null | head -n1)" ]]; then
  have_amd=1
fi

read_gpu_util() {
  [[ $GPU_AWARE -eq 1 ]] || { echo 0; return; }
  local n=0 a=0
  if (( have_nvidia )); then
    n=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk 'max<$1{max=$1}END{print max+0}')
  fi
  if (( have_amd )); then
    a=$(find /sys/class/drm -type f -name gpu_busy_percent -print0 2>/dev/null | xargs -0 -r awk 'max<$1{max=$1}END{print max+0}')
  fi
  (( n > a )) && echo "$n" || echo "$a"
}

# ----- GPU temperature (trigger) -----
# hwmon-first scan
read_gpu_temp_hwmon() {
  local t=0 cur=0 f nm

  # Prefer DRM-linked hwmon
  while IFS= read -r f; do
    nm="$(cat "$(dirname "$f")/name" 2>/dev/null || true)"
    if [[ "$nm" =~ (nvidia|amdgpu|radeon) ]]; then
      if [[ -r "$f" ]]; then
        cur=$(<"$f" 2>/dev/null || echo 0)
        [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
        (( cur > 1000 )) && cur=$((cur/1000))
        (( cur > t )) && t=$cur
      fi
    fi
  done < <(find /sys/class/drm -type f -path "*/device/hwmon/hwmon*/temp*_input" 2>/dev/null)

  # Fallback: generic hwmon scan
  if (( t == 0 )); then
    while IFS= read -r f; do
      nm="$(cat "$(dirname "$f")/name" 2>/dev/null || true)"
      if [[ "$nm" =~ (nvidia|amdgpu|radeon) ]]; then
        cur=$(<"$f" 2>/dev/null || echo 0)
        [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
        (( cur > 1000 )) && cur=$((cur/1000))
        (( cur > t )) && t=$cur
      fi
    done < <(find /sys/class/hwmon -type f -name "temp*_input" 2>/dev/null)
  fi

  echo "$t"
}

# Cached NVIDIA temp via nvidia-smi to avoid polling overhead
read_gpu_temp_nv() {
  command -v nvidia-smi >/dev/null 2>&1 || { echo 0; return; }
  local now ts=0 age=0 cached=0
  now=$(date +%s)

  if [[ -r "$GPU_TEMP_CACHE_FILE" ]]; then
    IFS=' ' read -r ts cached < "$GPU_TEMP_CACHE_FILE" || true
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    [[ "$cached" =~ ^[0-9]+$ ]] || cached=0
    age=$(( now - ts ))
    if (( age < GPU_TEMP_CACHE_SEC )); then
      echo "$cached"
      return
    fi
  fi

  local t
  t=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null \
      | awk 'max<$1{max=$1}END{print (max+0)}')
  [[ "$t" =~ ^[0-9]+$ ]] || t=0
  printf "%s %s\n" "$now" "$t" > "$GPU_TEMP_CACHE_FILE" 2>/dev/null || true
  echo "$t"
}

read_gpu_temp() {
  [[ $GPU_TEMP_AWARE -eq 1 ]] || { echo 0; return; }
  local t
  t=$(read_gpu_temp_hwmon)
  (( t > 0 )) && { echo "$t"; return; }
  t=$(read_gpu_temp_nv)
  echo "$t"
}

ppd_get() {
  powerprofilesctl get 2>/dev/null || echo balanced
}

ppd_set_retry() {
  local target="$1"
  local current
  current="$(ppd_get)"
  [[ "$current" == "$target" ]] && return 0

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
    sleep "$PPD_SET_RETRY_SLEEP"
  done
  return 1
}

# ===== Decision logic =====
decide_profile() {
  local load="$1" temp="$2" gpu="$3" short_busy="$4" gpu_temp="$5"
  local current; current="$(ppd_get)"

  # Manual override wins (sanitize allowed values)
  if [[ -f "$OVERRIDE_FILE" ]]; then
    local o; o=$(tr -d '\r\n\t ' <"$OVERRIDE_FILE")
    case "${o:-}" in
      power-saver|balanced|performance) echo "$o"; return ;;
      auto|'') : > "$OVERRIDE_FILE" ;;  # clear and continue auto
      *)        : > "$OVERRIDE_FILE" ;;  # scrub garbage
    esac
  fi

  # Immediate GPU temp trigger (your 37°C rule)
  if [[ $GPU_TEMP_AWARE -eq 1 ]] && (( gpu_temp >= GPU_TEMP_PERF_ENTER )); then
    echo "performance"
    return
  fi

  # Useful flags so temp/gpu can be disabled cleanly
  local hot=0 cool=1 busy_gpu=0 idle_gpu=1
  if [[ $TEMP_AWARE -eq 1 ]]; then
    (( temp >= TEMP_PERF_ENTER )) && hot=1
    (( temp <  TEMP_PERF_EXIT  )) && cool=1 || cool=0
  fi
  if [[ $GPU_AWARE -eq 1 ]]; then
    (( gpu >= GPU_PERF_ENTER )) && busy_gpu=1
    (( gpu <  GPU_PERF_EXIT  )) && idle_gpu=1 || idle_gpu=0
  fi

  # Spike accelerator: map PERF_ENTER (load units) heuristically to busy% and compare
  local spike_trigger
  spike_trigger=$(awk -v base="$SPIKE_CPU_BUSY_PCT_BASE_MULT" -v l="$LOAD_PERF_ENTER" -v f="$SPIKE_ACCEL_FRACTION" 'BEGIN{printf "%.0f", base*l*f}')
  if (( short_busy >= spike_trigger )); then
    echo "performance"
    return
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

  # Update files with minimal churn
  if [[ "$last_target" != "$target" ]]; then
    echo "$target" > "$LAST_APPLIED_FILE" || true
  fi
  if [[ ! -r "$STATE_FILE" ]] || [[ "$(cat "$STATE_FILE" 2>/dev/null)" != "$actual" ]]; then
    echo "$actual" > "$STATE_FILE" || true
  fi
}

# ===== Preflight =====
preflight() {
  need_cmd powerprofilesctl
  # Optional tools are checked lazily: bc, sensors, nvidia-smi, notify-send
}

# ===== Single-instance guard =====
single_instance() {
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    notify "Smart Power Profiles" "Already running."
    exit 0
  fi
}

# ===== Main loop =====
main_loop() {
  : > "$STATE_FILE" || true
  # warm up short-busy sampler
  read_cpu_short_busy_pct >/dev/null || true
  while true; do
    load="$(read_cpu_load)"
    temp="$(read_cpu_temp)"
    gpu="$(read_gpu_util)"
    short_busy="$(read_cpu_short_busy_pct)"
    gpu_temp=0
    if [[ $GPU_TEMP_AWARE -eq 1 ]]; then
      gpu_temp="$(read_gpu_temp)"
    fi
    target="$(decide_profile "$load" "$temp" "$gpu" "$short_busy" "$gpu_temp")"
    apply_profile "$target"
    sleep "$CHECK_INTERVAL"
  done
}

preflight
single_instance
main_loop
