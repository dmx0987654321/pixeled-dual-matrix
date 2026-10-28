# pixeled - dual Framework 16 LED matrices

This fork drives two independent Framework 16 LED matrices using the framework
built by Slowpaste on the main branch. Each is a 9x34 display with its own
configured layout and animation state.

## Panel configuration

The layouts are [config.left.json](./config.left.json) and
[config.right.json](./config.right.json). Edit either file independently to
choose what its panel displays. The service loads these side-specific files
rather than `config.json`.

The matrices share a USB vendor/product ID, so USB enumeration order cannot
reliably identify which is physically left or right. Use the USB topology
location to map each panel:

1. Connect both matrices and start pixeled once. Unassigned devices are logged
   with their USB location in `service.log` (or use `journalctl -u
   pixeled.service`).
2. Copy [panel-ports.json.example](./panel-ports.json.example) to
   `~/.config/pixeled/panel-ports.json`.
3. Replace `null` with the exact logged locations, for example:

       {
           "left": "1-3.1:1.0",
           "right": "1-3.2:1.0"
       }

The example locations are illustrative; use the values reported by your
machine. If you are unsure which connector is on which side, connect one
matrix at a time and note its location. USB topology locations remain stable
across reboots, but can change if the connection path or hub changes.

Each panel reconnects independently and is paced according to its own
firmware. Brightness, scroll-speed overrides, and sound visualization apply to
both panels; layout and panel animations remain independent.

Headphone plug animations are shown on the right panel. Charger animations
follow the side supplying power: this machine reports UCSI connectors 001 and
002 on the right, and 003 and 004 on the left. The mapping is in
`utils/plug_watch.py` if connector numbering differs on another machine. Socket
animations originate from each panel's outer edge; the left panel's animation
is mirrored so its port effects face outward too.

## Installation

Run `./setup.sh` as your normal user. It installs to `/opt/pixeled` by default;
set `PIXELED_INSTALL_DIR` to use another absolute path, for example:

    PIXELED_INSTALL_DIR="$HOME/Applications/pixeled" ./setup.sh

Setup checks for `pactl`, `parec`, `rsync`, and Python venv support, and
installs their packages on Fedora, Debian/Ubuntu/Linux Mint, and Arch Linux.
Configure the USB mapping above after the first run. See
[firmware/README.md](./firmware/README.md) for the patched matrix firmware.
