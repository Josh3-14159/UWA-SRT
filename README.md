# UWA-SRT — Small Radio Telescope Controller

A layered filesystem-based controller for a GS-232-compatible telescope
rotator, using a Waveshare RP2040 Zero exposed via
[rp2040-gpio-fs](https://github.com/Josh3-14159/rp2040-gpio-fs).

---

## Architecture

```
SDRangel
    |  GS-232 over /dev/srt_rotator (PTY)
    v
control/srt-gs232       reads enc/, writes go/
control/srt-watchdog    health checks, recovery

    |  /mnt/srt/go/  /mnt/srt/enc/
    v
hal/srt-go              inotify go/ -> drive/ (mutual exclusion)
hal/srt-init            journal watcher, re-runs srt-setup on reconnect
hal/srt-setup           builds /mnt/srt/ from config/pin_map

    |  /mnt/rp2040/gpio/
    v
rp2040fs@srt            FUSE filesystem (rp2040-gpio-fs)
RP2040 Zero hardware
```

**Layer contract:**
- `control/` never touches `/mnt/rp2040/` directly
- `control/` never writes `/mnt/srt/drive/` directly — always via `go/`
- `hal/` owns everything below `/mnt/srt/go/` and `/mnt/srt/enc/`

---

## Hardware

| Function      | Pin    |
|---------------|--------|
| Azimuth ADC   | GPIO26 |
| Elevation ADC | GPIO27 |
| Drive CW      | GPIO5  |
| Drive CCW     | GPIO4  |
| Drive UP      | GPIO3  |
| Drive DN      | GPIO2  |

Pin assignments live in `config/pin_map` and can be changed without touching
any script.

---

## Repository layout

```
UWA-SRT/
├── README.md
├── install.sh              deploy or update
│
├── hal/                    hardware abstraction layer
│   ├── srt-setup           builds /mnt/srt/ symlinks and initialises pins
│   ├── srt-init            journal watcher + sentinel writer
│   └── srt-go              inotify go/ daemon (mutual exclusion)
│
├── control/                higher-level control
│   ├── srt-gs232           GS-232 PTY daemon (Python)
│   └── srt-watchdog        periodic health check + recovery
│
├── config/                 machine-specific constants
│   ├── pin_map             GPIO assignments
│   ├── az_cal              azimuth encoder calibration
│   └── el_cal              elevation encoder calibration
│
└── systemd/                all unit files
    ├── srt-init.service
    ├── srt-go.service
    ├── srt-gs232.service
    ├── srt-watchdog.service
    ├── srt-watchdog.timer
    └── rp2040fs@srt.service.d/
        └── allow_other.conf    FUSE mount override
```

---

## Filesystem layout at runtime

```
/mnt/srt/
├── hal/            srt-setup  srt-init  srt-go    (scripts)
├── control/        srt-gs232  srt-watchdog
├── config/         pin_map  az_cal  el_cal
│
├── enc/
│   ├── az_raw  ->  /mnt/rp2040/gpio/gpio26/value
│   └── el_raw  ->  /mnt/rp2040/gpio/gpio27/value
│
├── drive/
│   ├── cw      ->  /mnt/rp2040/gpio/gpio5/value
│   ├── ccw     ->  /mnt/rp2040/gpio/gpio4/value
│   ├── up      ->  /mnt/rp2040/gpio/gpio3/value
│   └── dn      ->  /mnt/rp2040/gpio/gpio2/value
│
└── go/             cw  ccw  up  dn   (write 0 or 1)
```

### go/ interface

```bash
echo 1 > /mnt/srt/go/cw      # slew clockwise
echo 0 > /mnt/srt/go/cw      # stop
echo 0 > /mnt/srt/go/*       # stop all axes
```

Mutual exclusion is enforced by `srt-go`:
- `cw` / `ccw` are exclusive — writing `1` to one zeros the other
- `up` / `dn` are exclusive — same
- Az and El are independent — both axes may slew simultaneously

---

## Dependencies

- [rp2040-gpio-fs](https://github.com/Josh3-14159/rp2040-gpio-fs) firmware
  flashed, FUSE daemon built and installed
- `inotify-tools` — `sudo apt install inotify-tools`
- `python3` — `sudo apt install python3`
- A `srt` system user — `sudo useradd --system --no-create-home srt`

---

## Installation

```bash
# 1. One-time prerequisites
sudo apt install inotify-tools python3
sudo useradd --system --no-create-home srt

# 2. Clone and install
git clone https://github.com/<org>/UWA-SRT.git
cd UWA-SRT
sudo bash install.sh
```

`install.sh` will:
- Uncomment `user_allow_other` in `/etc/fuse.conf`
- Install a drop-in override for `rp2040fs@srt` that adds `-o allow_other`
- Copy all files to `/mnt/srt/` preserving `hal/` and `control/` structure
- Install and enable all systemd units
- Set ownership to `srt:srt` (watchdog runs as root)
- Delete the cloned repo directory

---

## Updating

```bash
git clone https://github.com/<org>/UWA-SRT.git
cd UWA-SRT
sudo bash install.sh
```

The installer detects the existing install, shows a diff, and asks for
confirmation. Config files are updated with per-file confirmation so local
calibration changes are not accidentally overwritten.

---

## Services

| Service | Role |
|---|---|
| `rp2040fs@srt` | FUSE mount — rp2040-gpio-fs, managed by udev |
| `srt-init` | Runs `srt-setup` at start and on every `Device alive.` reconnect |
| `srt-go` | inotify daemon — mutual exclusion, proxies `go/` to `drive/` |
| `srt-gs232` | GS-232 PTY daemon — SDRangel connects to `/dev/srt_rotator` |
| `srt-watchdog.timer` | Fires `srt-watchdog` every 30s |
| `srt-watchdog` | Health check — recovers broken filesystem or stopped services |

```bash
systemctl status srt-init srt-go srt-gs232 srt-watchdog.timer
journalctl -fu srt-init
journalctl -fu srt-go
journalctl -fu srt-gs232
journalctl -fu srt-watchdog
```

### Startup ordering

`srt-init` writes `/run/srt/ready` after the first successful `srt-setup`.
Both `srt-go` and `srt-gs232` poll for this file before starting, so nothing
races against an incomplete hardware initialisation.

### Keep-alives

`srt-go` pings systemd every 10s via `WATCHDOG=1`. If no ping is received
within 30s, systemd kills and restarts it. Both `srt-init` and `srt-go` use
`Restart=always` with a 5s back-off and a burst limit of 10 restarts per 2
minutes. `srt-watchdog` additionally checks filesystem and PTY state every 30s
and triggers recovery if anything is broken.

---

## Reconfiguring pins

Edit `/mnt/srt/config/pin_map` and replug the RP2040, or run:

```bash
sudo -u srt bash /mnt/srt/hal/srt-setup
```

## Calibration

Edit `/mnt/srt/config/az_cal` or `/mnt/srt/config/el_cal`. `srt-gs232` reads
calibration on every position conversion so changes take effect immediately
with no restart required.

## SDRangel setup

In SDRangel, configure the rotator controller:
- **Type:** GS-232
- **Device:** `/dev/srt_rotator`
- **Baud rate:** 9600 (any value — PTY ignores baud)

