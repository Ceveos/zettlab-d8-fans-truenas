#!/bin/bash
# zettlab_d8_fans.sh — Build, load, and control Zettlab D8 NAS fans.
# Designed to run every minute via cron. Self-bootstrapping: if the kernel
# module isn't loaded, it builds (via Docker) and loads it automatically.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$SCRIPT_DIR/zettlab_d8_fans.log"
STATE_DIR="$SCRIPT_DIR/state"
STATE_FILE="$STATE_DIR/last_pwm"
HEARTBEAT_FILE="$STATE_DIR/heartbeat_counter"
LOCK_FILE="/run/zettlab_d8_fans.lock"
CONF_FILE="$SCRIPT_DIR/fan_curve.conf"

KVER="$(uname -r)"
BUILD_DIR="$SCRIPT_DIR/built/$KVER"
KO_CACHE="$BUILD_DIR/zettlab_d8_fans.ko"

# Fan curve defaults (overridden by fan_curve.conf)
FAN_CURVE="33:92 38:120 42:145 46:165 50:183"
PWM_MIN=70
PWM_FALLBACK=145
TEMP_WARNING=50
TEMP_CRITICAL=55
HYSTERESIS_DOWN=15
HEARTBEAT_INTERVAL=15

mkdir -p "$STATE_DIR" "$BUILD_DIR"
touch "$LOG"

# Trim log to last 500 lines if it's grown large
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [zettlab-d8-fans] $*" >> "$LOG"
}

if [ -f "$CONF_FILE" ]; then
  # shellcheck source=fan_curve.conf
  . "$CONF_FILE"
fi

# Prevent overlapping runs (build can take minutes — cron must not stack)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

# ─── Phase 1: Ensure the kernel module is loaded ────────────────────────

find_hwmon() {
  for f in /sys/class/hwmon/hwmon*/name; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null)" = "zettlab_d8_fans" ]; then
      dirname "$f"
      return 0
    fi
  done
  return 1
}

HWMON=""
if HWMON="$(find_hwmon)"; then
  : # Module loaded and hwmon ready — skip to fan control
elif lsmod | awk '{print $1}' | grep -qx "zettlab_d8_fans"; then
  # Module loaded but hwmon not yet visible — wait briefly
  for _ in $(seq 1 5); do
    sleep 1
    if HWMON="$(find_hwmon)"; then break; fi
  done
  if [ -z "$HWMON" ]; then
    log "ERROR: module loaded but hwmon node not found"
    exit 1
  fi
else
  # Module not loaded — build if necessary, then load

  # Clean stale kernel caches
  for d in "$SCRIPT_DIR/built"/*/; do
    [ -d "$d" ] || continue
    dname="$(basename "$d")"
    if [ "$dname" != "$KVER" ]; then
      log "Removing stale build cache for kernel $dname"
      rm -rf "$d"
    fi
  done

  if [ ! -f "$KO_CACHE" ]; then
    log "No cached module for kernel $KVER — building..."

    if [ ! -d "/lib/modules/$KVER/build" ]; then
      log "ERROR: missing kernel headers at /lib/modules/$KVER/build"
      exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
      log "ERROR: Docker not available — cannot build module (will retry)"
      exit 1
    fi

    if ! ping -c1 -W2 deb.debian.org >/dev/null 2>&1; then
      log "ERROR: network not available — cannot build module (will retry)"
      exit 1
    fi

    # Detect GCC version used to build the running kernel
    KERNEL_GCC_MAJOR=""
    if grep -qP 'gcc-\d+' /proc/version 2>/dev/null; then
      KERNEL_GCC_MAJOR="$(grep -oP 'gcc-\K\d+' /proc/version)"
    elif grep -qP 'gcc \(Debian \d+' /proc/version 2>/dev/null; then
      KERNEL_GCC_MAJOR="$(grep -oP 'gcc \(Debian \K\d+' /proc/version)"
    fi
    if [ -z "$KERNEL_GCC_MAJOR" ]; then
      log "WARNING: could not detect kernel GCC version, using default"
      GCC_PKG="gcc"
      CC_CMD="gcc"
    else
      log "Kernel built with GCC $KERNEL_GCC_MAJOR"
      GCC_PKG="gcc-$KERNEL_GCC_MAJOR"
      CC_CMD="gcc-$KERNEL_GCC_MAJOR"
    fi

    DOCKER_IMAGE="debian:sid"
    if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
      log "Pulling $DOCKER_IMAGE..."
      if ! docker pull "$DOCKER_IMAGE" >> "$LOG" 2>&1; then
        log "ERROR: failed to pull $DOCKER_IMAGE"
        exit 1
      fi
    fi

    BUILD_TMP="$(mktemp -d)"
    trap 'rm -rf "$BUILD_TMP"' EXIT
    cp "$SCRIPT_DIR/zettlab_d8_fans.c" "$SCRIPT_DIR/Makefile" "$BUILD_TMP/"

    if ! docker run --rm \
        -e "GCC_PKG=$GCC_PKG" \
        -e "CC_CMD=$CC_CMD" \
        -v "/lib/modules/$KVER/build:/kernel-headers:ro" \
        -v "$BUILD_TMP:/src" \
        "$DOCKER_IMAGE" \
        bash -c 'set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq make "$GCC_PKG" kmod libelf-dev 2>&1
            cd /src
            make CC="$CC_CMD" -C /kernel-headers M=/src clean
            make CC="$CC_CMD" -C /kernel-headers M=/src modules
        ' >> "$LOG" 2>&1; then
      log "ERROR: Docker build failed — check log for details"
      exit 1
    fi

    if [ ! -f "$BUILD_TMP/zettlab_d8_fans.ko" ]; then
      log "ERROR: build completed but .ko not produced"
      exit 1
    fi

    mkdir -p "$BUILD_DIR"
    mv -f "$BUILD_TMP/zettlab_d8_fans.ko" "$KO_CACHE"
    log "Module built and cached at $KO_CACHE"
  fi

  if ! insmod "$KO_CACHE" >> "$LOG" 2>&1; then
    # Could fail because another process loaded it in the meantime
    if lsmod | awk '{print $1}' | grep -qx "zettlab_d8_fans"; then
      log "Module was already loaded"
    else
      log "ERROR: insmod failed"
      exit 1
    fi
  fi
  log "Module loaded for kernel $KVER"

  # Clear stale state so fan control always writes a fresh PWM after loading
  rm -f "$STATE_FILE" "$HEARTBEAT_FILE"

  # Wait for hwmon node to appear
  for _ in $(seq 1 10); do
    if HWMON="$(find_hwmon)"; then break; fi
    sleep 1
  done
  if [ -z "$HWMON" ]; then
    log "ERROR: module loaded but hwmon node not found after 10s"
    exit 1
  fi
  log "hwmon: $HWMON"
fi

# ─── Phase 2: Control HDD fans ──────────────────────────────────────────

PWM1="$HWMON/pwm1"
PWM2="$HWMON/pwm2"

if [ ! -w "$PWM1" ] || [ ! -w "$PWM2" ]; then
  log "ERROR: pwm files not writable: $PWM1 $PWM2"
  exit 1
fi

DISKS="$(lsblk --nodeps -rno NAME,TYPE 2>/dev/null \
         | awk '$2=="disk" {print "/dev/"$1}' || true)"

if [ -z "${DISKS:-}" ]; then
  log "ERROR: no disks found to monitor"
  exit 1
fi

HOTTEST=""
HOTTEST_DISK=""

get_temp() {
  local disk="$1"
  local out temp

  out="$(timeout 10 smartctl -a "$disk" 2>/dev/null || true)"

  # ATA/SATA: attribute 194 (Temperature_Celsius) or 190 (Airflow_Temperature_Cel)
  temp="$(echo "$out" \
    | awk '/Temperature_Celsius|Airflow_Temperature_Cel/ { print $10; exit }')"

  # NVMe fallback: "Temperature:    35 Celsius"
  if [ -z "${temp:-}" ]; then
    temp="$(echo "$out" \
      | awk -F: '/Temperature:/ { gsub(/^[ \t]+/,"",$2); gsub(/ .*/,"",$2); print $2; exit }')"
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
    CHANGED=0
  elif [ "$DIFF" -lt 0 ] && [ "${DIFF#-}" -lt "$HYSTERESIS_DOWN" ]; then
    CHANGED=0
  fi
fi

# Heartbeat: log status periodically even when PWM is unchanged
BEAT="$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"
if ! [[ "$BEAT" =~ ^[0-9]+$ ]]; then BEAT=0; fi
BEAT=$(( BEAT + 1 ))
if [ "$BEAT" -ge "$HEARTBEAT_INTERVAL" ]; then
  BEAT=0
  log "heartbeat: pwm=${LAST_PWM:-unknown} target=$TARGET_PWM $REASON"
fi
echo "$BEAT" > "$HEARTBEAT_FILE"

if [ "$CHANGED" -eq 0 ]; then
  exit 0
fi

# Write PWM to both HDD fan channels
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
