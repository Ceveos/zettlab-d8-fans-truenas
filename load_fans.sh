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

# Trim log to last 500 lines if it has grown large
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

# Already loaded — nothing to do
if lsmod | awk '{print $1}' | grep -qx "zettlab_d8_fans"; then
  log "Module already loaded, skipping."
  exit 0
fi

# Kernel headers are required for the build
if [ ! -d "/lib/modules/$KVER/build" ]; then
  log "ERROR: Missing kernel headers at /lib/modules/$KVER/build"
  exit 1
fi

# Build the module if not cached for this kernel
if [ ! -f "$KO_CACHE" ]; then
  log "No cached build for $KVER — building via Docker..."

  # --- Dependency: Docker daemon ---
  log "Waiting for Docker daemon..."
  for attempt in $(seq 1 30); do
    if docker info >/dev/null 2>&1; then
      break
    fi
    if [ "$attempt" -eq 30 ]; then
      log "ERROR: Docker daemon not available after 60s."
      log "TrueNAS may not have Docker enabled, or it has not started yet."
      exit 1
    fi
    sleep 2
  done

  # --- Dependency: Network (needed for image pull + apt-get) ---
  log "Waiting for network..."
  for attempt in $(seq 1 15); do
    if ping -c1 -W2 deb.debian.org >/dev/null 2>&1; then
      break
    fi
    if [ "$attempt" -eq 15 ]; then
      log "ERROR: Network not available after 30s (cannot reach deb.debian.org)."
      exit 1
    fi
    sleep 2
  done

  # --- Detect GCC version used to build the kernel ---
  KERNEL_GCC_MAJOR=""
  if grep -qP 'gcc-\d+' /proc/version 2>/dev/null; then
    KERNEL_GCC_MAJOR="$(grep -oP 'gcc-\K\d+' /proc/version)"
  elif grep -qP 'gcc \(Debian \d+' /proc/version 2>/dev/null; then
    KERNEL_GCC_MAJOR="$(grep -oP 'gcc \(Debian \K\d+' /proc/version)"
  fi
  if [ -z "$KERNEL_GCC_MAJOR" ]; then
    log "WARNING: Could not detect kernel GCC version from /proc/version."
    log "Falling back to default gcc in container."
    GCC_PKG="gcc"
    CC_CMD="gcc"
  else
    log "Kernel was built with GCC $KERNEL_GCC_MAJOR"
    GCC_PKG="gcc-$KERNEL_GCC_MAJOR"
    CC_CMD="gcc-$KERNEL_GCC_MAJOR"
  fi

  # Use debian:sid — always carries every supported GCC version
  DOCKER_IMAGE="debian:sid"
  if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    log "Pulling $DOCKER_IMAGE..."
    if ! docker pull "$DOCKER_IMAGE" >> "$LOG" 2>&1; then
      log "ERROR: Failed to pull $DOCKER_IMAGE."
      exit 1
    fi
  fi

  # Build in an isolated tmpdir so source stays read-only
  BUILD_TMP="$(mktemp -d)"
  trap 'rm -rf "$BUILD_TMP"' EXIT
  cp "$SRC_DIR/zettlab_d8_fans.c" "$SRC_DIR/Makefile" "$BUILD_TMP/"

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
    log "ERROR: Docker build failed — check log for details."
    exit 1
  fi

  if [ ! -f "$BUILD_TMP/zettlab_d8_fans.ko" ]; then
    log "ERROR: Build completed but zettlab_d8_fans.ko was not produced."
    exit 1
  fi

  mv -f "$BUILD_TMP/zettlab_d8_fans.ko" "$KO_CACHE"
  log "Build cached at $KO_CACHE"
fi

# Load the module
if insmod "$KO_CACHE" >> "$LOG" 2>&1; then
  log "Module loaded successfully."
else
  log "ERROR: insmod failed (exit code $?)."
  exit 1
fi

# Wait for hwmon node to appear
for i in $(seq 1 10); do
  for f in /sys/class/hwmon/hwmon*/name; do
    [ -f "$f" ] || continue
    if [ "$(cat "$f" 2>/dev/null)" = "zettlab_d8_fans" ]; then
      log "hwmon path: $(dirname "$f")"
      exit 0
    fi
  done
  sleep 1
done

log "ERROR: Module loaded but hwmon node not found after 10s."
exit 1
