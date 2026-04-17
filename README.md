# Zettlab D8 Fan Control

Kernel module and automatic fan control for the [Zettlab D8 Ultra AI NAS](https://zettlab.com/).

Exposes all three fan channels (two HDD, one CPU) via the Linux hwmon subsystem and
manages HDD fan speed based on disk temperatures using a configurable fan curve.

## Requirements

- Secure boot disabled (or custom MOK enrolled)
- `smartmontools` (for disk temperature monitoring via `smartctl`)
- **Standard Linux:** DKMS and kernel headers
- **TrueNAS SCALE:** Docker (used to compile the kernel module on the immutable root filesystem)

## Install

### Standard Linux (DKMS)

```bash
# Copy sources
sudo mkdir -p /usr/src/zettlab-d8-fans-0.0.2
sudo cp zettlab_d8_fans.c Makefile dkms.conf /usr/src/zettlab-d8-fans-0.0.2/

# Build and install
sudo dkms add    -m zettlab-d8-fans -v 0.0.2
sudo dkms build  -m zettlab-d8-fans -v 0.0.2
sudo dkms install -m zettlab-d8-fans -v 0.0.2

# Load now
sudo modprobe zettlab_d8_fans

# Load automatically at boot
echo zettlab_d8_fans | sudo tee /etc/modules-load.d/zettlab_d8_fans.conf
```

The hwmon interface appears under `/sys/class/hwmon/`. Find the node with:

```bash
cat /sys/class/hwmon/hwmon*/name   # look for "zettlab_d8_fans"
```

### TrueNAS SCALE

Add a single cron job — no Post Init script is needed:

1. **System Settings → Advanced → Cron Jobs**
2. Command: `/mnt/<your-pool>/path/to/zettlab_d8_fans.sh`
3. Schedule: every minute (`* * * * *`)
4. Run as: **root**

The script is fully self-bootstrapping. On first run it builds the kernel module
via Docker, loads it, and starts controlling fans. Subsequent runs (every minute)
only adjust fan speed. After a TrueNAS upgrade, the new kernel is detected and
the module is rebuilt automatically.

Docker and network connectivity are only needed for the initial build (or after
a kernel upgrade). If either is unavailable, the script exits and retries on the
next cron run.

## How It Works

Each cron invocation follows this flow:

```
hwmon node exists? ──yes──▶ control fans (read temps, apply curve, write PWM)
       │ no
module loaded? ──yes──▶ wait briefly for hwmon ──▶ control fans
       │ no
.ko cached for this kernel? ──yes──▶ insmod ──▶ control fans
       │ no
docker + network available? ──no──▶ exit (retry next minute)
       │ yes
build module via Docker ──▶ cache .ko ──▶ insmod ──▶ control fans
```

- **`zettlab_d8_fans.sh`** handles the entire lifecycle: build, load, and fan control.
  Uses `flock` to prevent overlapping runs (a build may take several minutes).
- **`fan_curve.conf`** contains the fan curve and tunable parameters.
  Changes take effect on the next cron run — no restart needed.

## Fan Curve Configuration

Edit `fan_curve.conf`:

```bash
# TEMP_THRESHOLD:PWM_VALUE (space-separated, ascending temperature)
FAN_CURVE="33:92 38:120 42:145 46:165 50:183"
PWM_MIN=70                # PWM below the lowest threshold
PWM_FALLBACK=145          # PWM when no temperatures can be read
TEMP_WARNING=50           # Log a WARNING above this temperature (°C)
TEMP_CRITICAL=55          # Force fans to maximum above this temperature (°C)
HYSTERESIS_DOWN=15        # Suppress PWM decreases smaller than this
HEARTBEAT_INTERVAL=15     # Log a heartbeat every N cron runs (~15 min)
```

## Hardware

| Channel | Label   | Default mode | Controlled by        |
|---------|---------|--------------|----------------------|
| Fan 1   | Disks 1 | Manual       | `zettlab_d8_fans.sh` |
| Fan 2   | Disks 2 | Manual       | `zettlab_d8_fans.sh` |
| Fan 3   | CPU     | Auto (BIOS)  | BIOS/EC              |

PWM range is **0–183** (hardware-specific — not the standard 0–255 hwmon scale).
Fan 3 can be switched to manual control by writing `1` to `pwm3_enable`.

### lm-sensors

Add to `/etc/sensors3.conf` to rescale PWM values to the standard 0–200 range:

```
chip "zettlab_d8_fans-*"
    compute pwm1 (@ * 200 / 183), (@ * 183 / 200)
    compute pwm2 (@ * 200 / 183), (@ * 183 / 200)
    compute pwm3 (@ * 200 / 183), (@ * 183 / 200)
```

## Logs

All events are logged to `zettlab_d8_fans.log` (auto-trimmed to 500 lines).

- Module build/load events
- Fan speed changes with disk temperatures
- Temperature warnings and critical alerts
- Periodic heartbeat (every ~15 minutes by default)

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "hwmon node not found" | Check if module is loaded: `lsmod \| grep zettlab` |
| "no disks found" | Verify SMART-capable disks: `smartctl --scan` |
| Permission denied on pwm files | Script must run as root |
| Build fails | Ensure Docker is running, network is up, and disk has space. Check log for GCC version issues. |
| Module won't load after upgrade | Delete the `built/` directory — it will be rebuilt on next run |
| Fans not responding | Verify hwmon path: `cat /sys/class/hwmon/hwmon*/name` |

## Uninstall

### Standard Linux (DKMS)

```bash
sudo dkms remove -m zettlab-d8-fans -v 0.0.2 --all
sudo rm -rf /usr/src/zettlab-d8-fans-0.0.2
sudo rm -f /etc/modules-load.d/zettlab_d8_fans.conf
```

### TrueNAS

1. Remove the cron job from **System Settings → Advanced → Cron Jobs**
2. Unload the module: `rmmod zettlab_d8_fans`
3. Delete the directory from your dataset

> **Note:** When the module is unloaded, fans remain at their last-set PWM value.
> The CPU fan (fan 3) is not affected if left in auto mode (default).

## Credits

Thanks to the [Zettlab](https://zettlab.com/) team for providing the MMIO register
documentation used to build this driver.
