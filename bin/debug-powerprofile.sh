#!/usr/bin/env bash
echo "=== Smart Power Profiles Debug ==="
echo "Time: $(date)"
echo

# CPU load (1-minute average)
LOAD=$(awk '{print $1}' /proc/loadavg)
echo "CPU Load (1-min avg): $LOAD"

# CPU package temperature
TEMP=$(sensors 2>/dev/null | awk '/Package id 0:/ {gsub("\\+|°C",""); print int($4)}' | head -n1)
[[ -z "$TEMP" ]] && TEMP="N/A"
echo "CPU Package Temp: $TEMP °C"

# NVIDIA GPU utilization + power
if command -v nvidia-smi >/dev/null; then
  line=$(nvidia-smi --query-gpu=utilization.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -n1)
  GPU_UTIL=$(awk -F',' '{gsub(" ",""); print $1+0}' <<<"$line")
  GPU_PWR=$(awk -F',' '{gsub(" ",""); print $2+0}' <<<"$line")
  echo "GPU Utilization: ${GPU_UTIL}%"
  echo "GPU Power Draw:  ${GPU_PWR} W"
else
  echo "No NVIDIA GPU detected."
fi

# Currently active GNOME power profile
PROFILE=$(powerprofilesctl get 2>/dev/null)
echo "Current power profile: $PROFILE"

# Thresholds from daemon (for reference)
echo
echo "Thresholds:"
grep -E "^(LOAD|TEMP|GPU)_BALANCED|^(LOAD|TEMP|GPU)_PERF" ~/Projects/smart-power-profiles/bin/auto-powerprofile.sh

echo
echo "=== End Debug ==="
