#!/bin/bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
KVER="$(uname -r)"
BUILD_DIR="$SRC_DIR/built/$KVER"
KO_CACHE="$BUILD_DIR/zettlab_d8_fans.ko"
LOG="$SRC_DIR/load_fans.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [zettlab-fans] $*" | tee -a "$LOG"
}

mkdir -p "$BUILD_DIR"
touch "$LOG"

# Trim log to last 500 lines if it's grown large
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
  tail -n 500 "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi

log "Boot — kernel $KVER"

# Clean up cached builds for old kernel versions
for d in "$SRC_DIR/built"/*/; do
  [ -d "$d" ] || continue
  dname="$(basename "$d")"
  if [ "$dname" != "$KVER" ]; then
    log "Removing stale build cache for kernel $dname"
    rm -rf "$d"
  fi
done

if lsmod | awk '{print $1}' | grep -qx "zettlab_d8_fans"; then
  log "Module already loaded, skipping."
  exit 0
fi

if [ ! -d "/lib/modules/$KVER/build" ]; then
  log "ERROR: Missing kernel headers at /lib/modules/$KVER/build"
  exit 1
fi

if [ ! -f "$KO_CACHE" ]; then
  log "No cached build for $KVER — rebuilding via Docker..."

  # Use a temporary build directory so source is mounted read-only
  BUILD_TMP="$(mktemp -d)"
  cp "$SRC_DIR/zettlab_d8_fans.c" "$SRC_DIR/Makefile" "$BUILD_TMP/"

  if ! docker image inspect debian:bookworm >/dev/null 2>&1; then
    log "Pulling debian:bookworm image..."
    if ! docker pull debian:bookworm >> "$LOG" 2>&1; then
      log "ERROR: Failed to pull debian:bookworm — is the network available?"
      rm -rf "$BUILD_TMP"
      exit 1
    fi
  fi

  if ! docker run --rm \
      -v "/lib/modules/$KVER/build:/kernel-headers:ro" \
      -v "$BUILD_TMP:/src" \
      debian:bookworm \
      bash -lc '
          set -euo pipefail
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq
          apt-get install -y -qq make gcc kmod libelf1 libelf-dev 2>&1
          cd /src
          make -C /kernel-headers M=/src clean
          make -C /kernel-headers M=/src modules
      ' >> "$LOG" 2>&1; then
    log "ERROR: Docker build failed — check log for details."
    rm -rf "$BUILD_TMP"
    exit 1
  fi

  if [ ! -f "$BUILD_TMP/zettlab_d8_fans.ko" ]; then
    log "ERROR: Build finished but zettlab_d8_fans.ko was not produced."
    rm -rf "$BUILD_TMP"
    exit 1
  fi

  mv -f "$BUILD_TMP/zettlab_d8_fans.ko" "$KO_CACHE"
  rm -rf "$BUILD_TMP"
  log "Build succeeded → $KO_CACHE"
fi

if insmod "$KO_CACHE" >> "$LOG" 2>&1; then
  log "Module loaded successfully."
else
  log "ERROR: insmod failed."
  exit 1
fi

# Wait for hwmon node to appear
for i in {1..10}; do
  for f in /sys/class/hwmon/hwmon*/name; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null)" = "zettlab_d8_fans" ]; then
      log "hwmon path: $(dirname "$f")"
      exit 0
    fi
  done
  sleep 1
done

log "ERROR: Module loaded, but hwmon node was not found after 10s."
exit 1
