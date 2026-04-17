#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$SCRIPT_DIR/control_hdd_fans.log"
STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$STATE_DIR/last_pwm"
HEARTBEAT_FILE="$STATE_DIR/heartbeat_counter"
LOCK_FILE="/run/control_hdd_fans.lock"
CONF_FILE="$SCRIPT_DIR/fan_curve.conf"

# Defaults (overridden by config file)
FAN_CURVE="33:92 38:120 42:145 46:165 50:183"
PWM_MIN=70
PWM_FALLBACK=145
TEMP_WARNING=50
TEMP_CRITICAL=55
HYSTERESIS_DOWN=15
HEARTBEAT_INTERVAL=15

mkdir -p "$STATE_DIR"
touch "$LOG"

# Trim log to last 500 lines if it's grown large
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [zettlab-fans-ctrl] $*" >> "$LOG"
}

# Load config
if [ -f "$CONF_FILE" ]; then
  # shellcheck source=fan_curve.conf
  . "$CONF_FILE"
fi

# Prevent overlapping runs
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

# Find the hwmon path dynamically
HWMON=""
for f in /sys/class/hwmon/hwmon*/name; do
  [ -f "$f" ] || continue
  if [ "$(cat "$f" 2>/dev/null)" = "zettlab_d8_fans" ]; then
    HWMON="$(dirname "$f")"
    break
  fi
done

if [ -z "${HWMON:-}" ]; then
  log "ERROR: zettlab_d8_fans hwmon node not found"
  exit 1
fi

PWM1="$HWMON/pwm1"
PWM2="$HWMON/pwm2"

if [ ! -w "$PWM1" ] || [ ! -w "$PWM2" ]; then
  log "ERROR: pwm files are not writable: $PWM1 $PWM2"
  exit 1
fi

# Enumerate disks via lsblk (catches sda through sdz, sdaa+, and nvme)
DISKS="$(lsblk --nodeps -rno NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}' || true)"

if [ -z "${DISKS:-}" ]; then
  log "ERROR: no disks found to monitor"
  exit 1
fi

HOTTEST=""
HOTTEST_DISK=""

get_temp() {
  local disk="$1"
  local out temp

  # Single smartctl call — parse both ATA and NVMe formats
  out="$(timeout 10 smartctl -a "$disk" 2>/dev/null || true)"

  # ATA/SATA: attribute 194 (Temperature_Celsius) or 190 (Airflow_Temperature_Cel)
  temp="$(echo "$out" | awk '/Temperature_Celsius|Airflow_Temperature_Cel/ { print $10; exit }')"

  # NVMe fallback: "Temperature:    35 Celsius"
  if [ -z "${temp:-}" ]; then
    temp="$(echo "$out" | awk -F: '/Temperature:/ { gsub(/^[ \t]+/, "", $2); gsub(/ .*/, "", $2); print $2; exit }')"
  fi

  if [[ "${temp:-}" =~ ^[0-9]+$ ]]; then
    echo "$temp"
  fi
}

for disk in $DISKS; do
  temp="$(get_temp "$disk" || true)"
  if [ -n "${temp:-}" ]; then
    if [ -z "${HOTTEST:-}" ] || [ "$temp" -gt "$HOTTEST" ]; then
      HOTTEST="$temp"
      HOTTEST_DISK="$disk"
    fi
  fi
done

# Determine target PWM from fan curve
if [ -z "${HOTTEST:-}" ]; then
  TARGET_PWM="$PWM_FALLBACK"
  REASON="fallback-no-temp"
else
  TARGET_PWM="$PWM_MIN"
  for entry in $FAN_CURVE; do
    threshold="${entry%%:*}"
    pwm="${entry##*:}"
    if [ "$HOTTEST" -ge "$threshold" ]; then
      TARGET_PWM="$pwm"
    fi
  done
  REASON="hottest=${HOTTEST}C disk=${HOTTEST_DISK}"

  # Critical / warning alerting
  if [ "$HOTTEST" -ge "$TEMP_CRITICAL" ]; then
    TARGET_PWM=183
    log "CRITICAL: $HOTTEST_DISK at ${HOTTEST}C — fans forced to maximum"
  elif [ "$HOTTEST" -ge "$TEMP_WARNING" ]; then
    log "WARNING: $HOTTEST_DISK at ${HOTTEST}C"
  fi
fi

# Hysteresis: always allow increases, suppress small decreases
LAST_PWM=""
if [ -f "$STATE_FILE" ]; then
  LAST_PWM="$(cat "$STATE_FILE" 2>/dev/null || true)"
fi

CHANGED=1
if [[ "${LAST_PWM:-}" =~ ^[0-9]+$ ]]; then
  DIFF=$(( TARGET_PWM - LAST_PWM ))
  if [ "$DIFF" -eq 0 ]; then
    # No change at all
    CHANGED=0
  elif [ "$DIFF" -lt 0 ] && [ "${DIFF#-}" -lt "$HYSTERESIS_DOWN" ]; then
    # Small decrease — suppress
    CHANGED=0
  fi
fi

# Heartbeat: log status periodically even when no change
BEAT="$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"
if ! [[ "$BEAT" =~ ^[0-9]+$ ]]; then BEAT=0; fi
BEAT=$(( BEAT + 1 ))
if [ "$BEAT" -ge "$HEARTBEAT_INTERVAL" ]; then
  BEAT=0
  CURRENT_PWM="${LAST_PWM:-unknown}"
  log "heartbeat: pwm=$CURRENT_PWM target=$TARGET_PWM $REASON"
fi
echo "$BEAT" > "$HEARTBEAT_FILE"

if [ "$CHANGED" -eq 0 ]; then
  exit 0
fi

# Write PWM to both fan channels — handle errors gracefully
WRITE_ERRORS=0
if ! echo "$TARGET_PWM" > "$PWM1" 2>/dev/null; then
  log "ERROR: failed to write $TARGET_PWM to $PWM1"
  WRITE_ERRORS=1
fi
if ! echo "$TARGET_PWM" > "$PWM2" 2>/dev/null; then
  log "ERROR: failed to write $TARGET_PWM to $PWM2"
  WRITE_ERRORS=1
fi

echo "$TARGET_PWM" > "$STATE_FILE"

if [ "$WRITE_ERRORS" -eq 0 ]; then
  log "Set pwm1/pwm2 to $TARGET_PWM ($REASON)"
else
  log "Set pwm (with errors) to $TARGET_PWM ($REASON)"
fi
