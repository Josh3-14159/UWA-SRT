# srt — Small Radio Telescope Controller

A filesystem abstraction layer for controlling a GS-232-compatible telescope
rotator using a Waveshare RP2040 Zero exposed via
[rp2040-gpio-fs](https://github.com/Josh3-14159/rp2040-gpio-fs).

The RP2040 runs the `rp2040-gpio-fs` firmware, which presents its GPIO, ADC,
and PWM peripherals as a FUSE filesystem at `/mnt/rp2040/`. This layer sits on
top of that and provides a clean, pin-agnostic interface for higher-level
software (e.g. a GS-232 daemon talking to SDRangel).

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

Pin assignments are defined in `config/pin_map` and can be changed without
touching any script.

---

## Filesystem layout

After installation and with the RP2040 connected, `/mnt/srt/` looks like this:

```
/mnt/srt/
├── enc/
│   ├── az_raw      → /mnt/rp2040/gpio/gpio26/value  (ADC raw counts + volts)
│   └── el_raw      → /mnt/rp2040/gpio/gpio27/value
│
├── drive/
│   ├── cw          → /mnt/rp2040/gpio/gpio5/value   (write 0 or 1)
│   ├── ccw         → /mnt/rp2040/gpio/gpio4/value
│   ├── up          → /mnt/rp2040/gpio/gpio3/value
│   └── dn          → /mnt/rp2040/gpio/gpio2/value
│
├── go/                                               (write 0 or 1 here)
│   ├── cw
│   ├── ccw
│   ├── up
│   └── dn
│
└── config/
    ├── pin_map     (GPIO assignments — source of truth)
    ├── az_cal      (azimuth encoder calibration constants)
    └── el_cal      (elevation encoder calibration constants)
```

### enc/

Symlinks directly to the FUSE ADC value files. Reading returns the raw format
from the firmware: `2048 1.6504` (raw 12-bit count and voltage). Higher-level
software is responsible for converting to degrees using the constants in
`config/az_cal` and `config/el_cal`.

### drive/

Symlinks to the FUSE GPIO output value files. Writing `1` or `0` directly
drives the motor controller pins. No mutual exclusion is enforced here — use
`go/` instead.

### go/

Plain files backed by the `srt-go` daemon. Writing `1` or `0` to a file here
is the recommended way to command motion:

```bash
echo 1 > /mnt/srt/go/cw      # start slewing clockwise
echo 0 > /mnt/srt/go/cw      # stop
echo 0 > /mnt/srt/go/*       # stop all axes
```

**Mutual exclusion is enforced per axis:**
- `cw` and `ccw` are exclusive — writing `1` to one automatically zeros the other
- `up` and `dn` are exclusive — same behaviour
- Az and El axes are independent — both may slew simultaneously

Reading a `go/` file returns the current commanded state (`0` or `1`).

---

## Dependencies

- [rp2040-gpio-fs](https://github.com/Josh3-14159/rp2040-gpio-fs) firmware
  flashed and FUSE daemon installed (`rp2040fs@srt.service` running)
- `inotify-tools` (`sudo apt install inotify-tools`)
- A `srt` system user (`sudo useradd --system --no-create-home srt`)

---

## Installation

```bash
# 1. Install dependencies
sudo apt install inotify-tools
sudo useradd --system --no-create-home srt

# 2. Clone and install
git clone <repo-url> srt-controller
cd srt-controller
sudo bash install.sh
```

`install.sh` will:
- Create `/mnt/srt/` and copy all files into place
- Install and enable `srt-init.service` and `srt-go.service`
- Set correct ownership to the `srt` user
- Delete the cloned repo directory (the live copy lives at `/mnt/srt/`)

After installation, plug in the RP2040. The services start automatically via
udev/systemd. To start manually:

```bash
systemctl start srt-init srt-go
```

---

## Services

| Service | Role |
|---|---|
| `rp2040fs@srt` | FUSE mount (from rp2040-gpio-fs) |
| `srt-init` | Watches journal for `Device alive.`, re-runs `srt-setup` on each reconnect |
| `srt-go` | inotify daemon — enforces mutual exclusion, proxies `go/` → `drive/` |

```bash
# Check status
systemctl status srt-init srt-go

# Watch logs
journalctl -fu srt-init
journalctl -fu srt-go
```

---

## Reconfiguring pins

Edit `/mnt/srt/config/pin_map` then run:

```bash
sudo -u srt bash /mnt/srt/srt-setup
```

Or simply replug the RP2040 — `srt-init` will call `srt-setup` automatically
on reconnect.

---

## Calibration

Edit `/mnt/srt/config/az_cal` and `/mnt/srt/config/el_cal`. Changes are picked
up by the GS-232 daemon on the next reconnect or daemon restart.
