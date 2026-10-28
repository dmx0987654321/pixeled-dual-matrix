# LED matrix firmware

The Framework 16 LED matrix runs a patched build of Framework's own firmware.
Stock, a greyscale frame takes ~170 ms to land; the build here takes ~15 ms,
which is what makes 60 fps greyscale possible at all.

## What is here

| File | |
| --- | --- |
| `ledmatrix-0.2.0-official.uf2` | upstream v0.2.0, unmodified, to roll back to |
| `ledmatrix-0.2.0-pixeled.uf2` | the same source with `ledmatrix-pixeled.patch` applied |
| `ledmatrix-pixeled.patch` | the changes, against upstream v0.2.0 |
| `flash-ledmatrix.sh` | flashes both matrices sequentially over USB |
| `bench-ledmatrix.py` | times where a command's milliseconds go |

Both builds report version 0.2.0. The pixeled one also sets the pre-release
flag, which is how `flash-ledmatrix.sh` tells them apart after flashing.

Run `sudo firmware/flash-ledmatrix.sh` to flash both matrices. The script
identifies each by its USB vendor/product ID and udev `ID_PATH`, not by
`/dev/ttyACM` numbering, then reboots, flashes, and verifies one panel before
moving on to the other. It stops `pixeled.service` while doing this and starts
it again afterward if it had been running.

Both matrices must be connected and running firmware before starting. The
script refuses to proceed unless it finds exactly two, and refuses if an
`RPI-RP2` drive is already present because that drive could belong to a
keyboard or another RP2040 module. If an error happens after the first panel
was flashed, that panel remains updated; fix the reported issue and run the
script again to complete the other one.

## What the patch changes

- **Don't redraw on the timer when nothing is animating.** The firmware
  rewrote an unchanged grid every 31 ms, spending a redraw's worth of I2C time
  out of every ~30 ms of incoming commands.
- **Don't redraw while staging greyscale columns.** `StageGreyCol` only writes
  the off-screen buffer, so there is nothing new to show yet. Redrawing anyway
  made one greyscale frame cost ten full redraws instead of one.
- **Add a `GlobalCurrent` command (0x30)** for the IS31FL3741's global current
  register, so the panel can be dimmed without squeezing the 256 PWM steps the
  picture is drawn with, the way the brightness setting does.
- **Fade to sleep in a tenth of the brightness per step** rather than a fixed
  5, so the fade takes about a second from any brightness instead of holding
  the firmware loop for five seconds at 255.

## Rebuilding

The patch applies to upstream v0.2.0 (verified against `13efc56`, which is
v0.2.0 plus two commits that do not touch these files):

    git clone https://github.com/FrameworkComputer/inputmodule-rs
    cd inputmodule-rs
    git checkout v0.2.0
    git apply /path/to/pixeled-dual-matrix/firmware/ledmatrix-pixeled.patch
    cargo make --cwd ledmatrix
    cargo make --cwd ledmatrix uf2

## Licensing

The two `.uf2` files and `ledmatrix-pixeled.patch` are derived from
[FrameworkComputer/inputmodule-rs](https://github.com/FrameworkComputer/inputmodule-rs),
which is MIT licensed, Copyright (c) 2023 Framework Computer Inc. That license
is in `LICENSE` here and covers those three files.

`flash-ledmatrix.sh` and `bench-ledmatrix.py` are pixeled's own, under the
WTFPL like the rest of the repository - see `LICENSE` at the top level.
