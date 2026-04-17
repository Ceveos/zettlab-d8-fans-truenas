# zettlab-d8-fans
DKMS-compatible kernel module for exposing the fans of the Zettlab D8 Ultra NAS via hwmon

## Requirements

- Secure boot disabled (unless you have setup your own MOK)
- Linux installed (tested on Ubuntu 25.10, kernel 6.17)
- DKMS (for standard Linux) or Docker (for TrueNAS)
- `smartmontools` (for disk temperature monitoring via `smartctl`)

## Install (Standard Linux / DKMS)

1. Download the Makefile, dkms.conf and zettlab_d8_fans.c to a folder (e.g. /usr/src/zettlab-d8-fans-0.0.2)
1. Add the module to DKMS - `dkms add -m zettlab-d8-fans -v 0.0.2`
1. Build the module - `dkms build -m zettlab-d8-fans -v 0.0.2`
1. Install the module - `dkms install -m zettlab-d8-fans -v 0.0.2`
1. Load the module - `modprobe zettlab_d8_fans`

The fan interface will now be available via `/sys/class/hwmon`. Run the command `cat /sys/class/hwmon/hwmon*/name` to find which
hwmon node the fans are available under (on my system it was `hwmon8`).

To load the module automatically at boot, create an entry in `/etc/modules-load.d`:

`echo zettlab_d8_fans | sudo tee /etc/modules-load.d/zettlab_d8_fans.conf`

## Install (TrueNAS SCALE)

TrueNAS has an immutable root filesystem, so DKMS cannot be used. Instead, `load_fans.sh`
builds the module at boot and caches it per kernel version.

The module is built inside a Docker container (`debian:sid`) which automatically installs
the exact GCC version matching your kernel (e.g., `gcc-14` for a GCC 14 kernel). Docker
and network connectivity are required at first boot (subsequent boots use the cached `.ko` file).

### Setup

1. Add `load_fans.sh` as a **Post Init** script in TrueNAS:
   - System Settings → Advanced → Init/Shutdown Scripts
   - Type: Script, When: Post Init
   - Path: `/mnt/<your-pool>/config/zettlab-d8-fans/load_fans.sh`

2. Add `control_hdd_fans.sh` as a **cron job** running every minute:
   - System Settings → Advanced → Cron Jobs
   - Command: `/mnt/<your-pool>/config/zettlab-d8-fans/control_hdd_fans.sh`
   - Schedule: every minute (`* * * * *`)
   - Run as: root

### How it works

- **`load_fans.sh`** runs at boot: builds the kernel module via Docker if not
  cached for the current kernel, loads it with `insmod`, and verifies the hwmon node appears.
  Old kernel caches are automatically cleaned up.
- **`control_hdd_fans.sh`** runs every minute via cron: reads disk temperatures with
  `smartctl`, applies a configurable fan curve, and writes PWM values to the hwmon sysfs
  interface. Uses `flock` to prevent overlapping runs.
- **`fan_curve.conf`** contains the fan curve thresholds, alert temperatures, and other
  tunable parameters. Edit this file to adjust fan behavior without modifying the script.

### Logs

- `load_fans.log` — module build and load events (only at boot)
- `control_hdd_fans.log` — fan speed changes, temperature warnings/alerts, periodic heartbeat

Both logs are automatically trimmed to prevent unbounded growth.

## Using

Fan 1 and 2 are the fans behind the disks, fan 3 is the CPU fan.

RPM is available in `fan1_input`, `fan2_input` and `fan3_input`

Fan 1 and 2 are manual (controlled by `control_hdd_fans.sh` on TrueNAS).
Fan 3 defaults to auto (BIOS/EC control). Set `pwm3_enable` to 1 for manual control,
or leave at 2 for automatic control.

Fan PWM accepts values 0–183, mapping to 0%–100% fan speed. Values outside this range are rejected.
This is a hardware-specific range, not the standard 0–255 hwmon scale.
Setting `pwm3` to 0 will revert the CPU fan to auto control.

Setting a value between 0 and 183 will scale fans from 0% to 100% (e.g. 50% is 91-92).

### Fan curve configuration

Edit `fan_curve.conf` to customise the fan curve:

```bash
# Format: TEMP_THRESHOLD:PWM_VALUE (space-separated, ascending temp)
FAN_CURVE="33:92 38:120 42:145 46:165 50:183"
PWM_MIN=70                # PWM below lowest threshold
PWM_FALLBACK=145          # PWM when no temps can be read
TEMP_WARNING=50           # Log WARNING above this temp
TEMP_CRITICAL=55          # Log CRITICAL above this temp
HYSTERESIS_DOWN=15        # Suppress PWM decreases smaller than this
HEARTBEAT_INTERVAL=15     # Log status every N cron runs (~15 min)
```

### lm-sensors output

If using lm-sensors to monitor fans, the following needs to be added to `/etc/sensors3.conf`:

```
chip "zettlab_d8_fans-*"
    compute pwm1 (@ * 200 / 183), (@ * 183 / 200)
    compute pwm2 (@ * 200 / 183), (@ * 183 / 200)
    compute pwm3 (@ * 200 / 183), (@ * 183 / 200)
```

## Configuration

Changes to `fan_curve.conf` take effect on the next cron run — no restart or reload is needed.

## TrueNAS Upgrades

On TrueNAS upgrade, `load_fans.sh` automatically detects the new kernel version, rebuilds the module, and caches the new `.ko` file. Old kernel caches are cleaned up automatically. No manual action is needed.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "hwmon node not found" in logs | Check if module is loaded: `lsmod \| grep zettlab` |
| "no disks found" | Ensure SMART-capable disks are present: `smartctl --scan` |
| Permission denied on pwm files | Script must run as root; check `pwm_enable` is set to 1 |
| Build fails | Check Docker is running, network is available, and disk has space. Check log for GCC version mismatch. |
| Module won't load after TrueNAS update | Delete `built/` directory and re-run `load_fans.sh` |
| Fans not responding to PWM changes | Verify hwmon path: `cat /sys/class/hwmon/hwmon*/name` |

## Uninstall

### Standard Linux (DKMS)

```bash
dkms remove -m zettlab-d8-fans -v 0.0.2 --all
rm -rf /usr/src/zettlab-d8-fans-0.0.2
rm -f /etc/modules-load.d/zettlab_d8_fans.conf
```

### TrueNAS

1. Remove the Post Init script and Cron Job from TrueNAS settings
2. Unload the module: `rmmod zettlab_d8_fans`
3. Delete the directory from your dataset

**Note:** When the module is unloaded, fans remain at their last-set PWM value. The CPU fan (fan 3) is not affected if left in auto mode (default).

## Credits

Thanks to the Zettlab team (support@zettlab.com) for sharing details on memory registers to control/monitor fans.

Code generated by ChatGPT. Please raise issues using GitHub issues on this repo.
