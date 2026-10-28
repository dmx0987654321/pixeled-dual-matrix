#!/usr/bin/env bash
# Set pixeled up on a Framework 16 with two LED matrix input modules, from a
# clone of this repository:
#
#   ./setup.sh                 everything below
#   ./setup.sh --no-firmware   leave the module's firmware alone
#   ./setup.sh --no-service    copy files and build the venv, install no unit
#   ./setup.sh --yes           don't ask before flashing
#   PIXELED_INSTALL_DIR=/path ./setup.sh   install somewhere other than /opt/pixeled
#
# It does, in order:
#
# 1. Installs the packages main.py shells out to (pactl and parec, for the
#    sound visualizer) and the ones needed to build the venv. Supports Fedora,
#    Debian/Ubuntu/Linux Mint, and Arch Linux.
# 2. Copies the repository to /opt/pixeled (or PIXELED_INSTALL_DIR) and builds
#    a venv there from requirements.txt. The service runs from the install
#    directory, not the clone, so editing the clone never disturbs a running
#    panel.
# 3. Installs and starts pixeled.service, running as the invoking user.
# 4. Flashes the patched firmware onto both matrices - see firmware/README.md for
#    what it changes and why the stock build is too slow for 60 fps greyscale.
#
# Re-running it is safe: it is the update path as well as the install, and it
# leaves the panel's learned and tuned state (power_peaks.json, scroll_speed)
# where it is.
set -euo pipefail

TARGET_DIR="${PIXELED_INSTALL_DIR:-/opt/pixeled}"
SERVICE_NAME="pixeled.service"
UNIT_FILE="/etc/systemd/system/$SERVICE_NAME"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(realpath -e "$SOURCE_DIR")"
TARGET_DIR="$(realpath -m "$TARGET_DIR")"

do_firmware=true
do_service=true
assume_yes=false
for arg in "$@"; do
  case "$arg" in
    --no-firmware)  do_firmware=false ;;
    --no-service)   do_service=false ;;
    --yes|-y)       assume_yes=true ;;
    -h|--help)      sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
    *)              echo "unknown option: $arg (try --help)" >&2; exit 1 ;;
  esac
done

say()  { echo "• $*"; }
warn() { echo "! $*" >&2; }
die()  { echo "✗ $*" >&2; exit 1; }

python_venv_available() {
  command -v python3 >/dev/null || return 1
  python3 - >/dev/null 2>&1 <<'PY'
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as temp_dir:
    result = subprocess.run(
        [sys.executable, "-m", "venv", f"{temp_dir}/check"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sys.exit(result.returncode)
PY
}

[ "${TARGET_DIR#/}" != "$TARGET_DIR" ] \
  || die "PIXELED_INSTALL_DIR must be an absolute path (got: $TARGET_DIR)"
case "$TARGET_DIR" in
  *[[:space:]]*) die "PIXELED_INSTALL_DIR must not contain whitespace (got: $TARGET_DIR)" ;;
esac
case "$TARGET_DIR/" in
  "$SOURCE_DIR/"*) die "PIXELED_INSTALL_DIR must not be inside the source directory" ;;
esac
case "$SOURCE_DIR/" in
  "$TARGET_DIR/"*) die "PIXELED_INSTALL_DIR must not contain the source directory" ;;
esac

# ── Who this is for ──────────────────────────────────────────────────────────

# Run as yourself, not as root: the service runs as you so it can reach your
# sound server and your ~/.cache/pixeled. The privileged steps sudo for
# themselves.
[ "$EUID" -ne 0 ] || die "run this as your own user, not with sudo - it will ask when it needs root"
RUN_USER="$(id -un)"
RUN_HOME="$HOME"

sudo -v || die "this needs sudo for the install directory, systemd and flashing"

product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
case "$product" in
  *"Laptop 16"*) ;;
  *) warn "this is a '$product', not a Framework 16 - carrying on, but the panel and the firmware expect one" ;;
esac

# ── 1. Packages ──────────────────────────────────────────────────────────────

if command -v dnf >/dev/null; then
  want=()
  if ! command -v pactl >/dev/null || ! command -v parec >/dev/null; then
    want+=(pulseaudio-utils)
  fi
  command -v rsync >/dev/null || want+=(rsync)
  python_venv_available || want+=(python3)
  if [ ${#want[@]} -gt 0 ]; then
    say "installing ${want[*]}"
    sudo dnf install -y "${want[@]}"
  fi
elif command -v apt-get >/dev/null; then
  want=()
  if ! command -v pactl >/dev/null || ! command -v parec >/dev/null; then
    want+=(pulseaudio-utils)
  fi
  command -v rsync >/dev/null || want+=(rsync)
  python_venv_available || want+=(python3-venv)
  if [ ${#want[@]} -gt 0 ]; then
    say "installing ${want[*]}"
    sudo apt-get update
    sudo apt-get install -y "${want[@]}"
  fi
elif command -v pacman >/dev/null; then
  want=()
  if ! command -v pactl >/dev/null || ! command -v parec >/dev/null; then
    want+=(pulseaudio)
  fi
  command -v rsync >/dev/null || want+=(rsync)
  python_venv_available || want+=(python)
  if [ ${#want[@]} -gt 0 ]; then
    say "installing ${want[*]}"
    sudo pacman -S --needed --noconfirm "${want[@]}"
  fi
else
  warn "no supported package manager found; checking required commands without installing them"
fi

missing=()
for command_name in pactl parec rsync python3; do
  command -v "$command_name" >/dev/null || missing+=("$command_name")
done
python_venv_available || missing+=("python3 venv support")
if [ ${#missing[@]} -gt 0 ]; then
  die "required commands or components are unavailable: ${missing[*]}; install them and rerun setup"
fi

# ── 2. The code, and its venv ────────────────────────────────────────────────

# --delete keeps the target from collecting files this repository has dropped,
# so everything the target maintains itself has to be spared by name.
EXCLUDES=(
  ".git/" ".claude/" "__pycache__/" "venv/" "service.log" "setup.sh" "deploy.sh"
  "display_mode" "scroll_speed"   # runtime state; a deploy must not reset the
                                  # panel's mode or throw away a tuned rate
  "power_peaks.json"    # the sand gauge's learned full scale; deleting it
                        # would relearn from scratch and mis-scale the flow
)
say "copying the repository to $TARGET_DIR"
sudo mkdir -p "$TARGET_DIR"
sudo rsync -a --delete "${EXCLUDES[@]/#/--exclude=}" "$SOURCE_DIR"/ "$TARGET_DIR"/
sudo chown -R "$RUN_USER:$RUN_USER" "$TARGET_DIR"

# Built with the system python, not copied: a venv carries absolute paths and
# the interpreter it was made with, and pixeled's own clone often holds a stale
# one from an older python that the current one cannot run.
if [ ! -x "$TARGET_DIR/venv/bin/python" ]; then
  say "building the venv with $(python3 -V)"
  python3 -m venv "$TARGET_DIR/venv"
fi
say "installing requirements.txt"
"$TARGET_DIR/venv/bin/pip" install --quiet --upgrade pip
"$TARGET_DIR/venv/bin/pip" install --quiet -r "$TARGET_DIR/requirements.txt"

# The panel is a USB serial device owned by the dialout group. A unit picks up
# its user's groups when it starts, so the service does not wait for a login -
# but an interactive shell does, which is what the note is about.
if ! id -nG "$RUN_USER" | tr ' ' '\n' | grep -qx dialout; then
  say "adding $RUN_USER to dialout, for the panel's serial port"
  sudo usermod -aG dialout "$RUN_USER"
  warn "log out and back in before talking to the panel from a shell yourself"
fi

mkdir -p "$RUN_HOME/.config/pixeled" "$RUN_HOME/.cache/pixeled"

# ── 3. The service ───────────────────────────────────────────────────────────

if $do_service; then
  say "installing $SERVICE_NAME"
  sudo tee "$UNIT_FILE" >/dev/null <<UNIT
[Unit]
Description=Pixeled Display Service
After=network.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$TARGET_DIR
ExecStart=$TARGET_DIR/venv/bin/python $TARGET_DIR/main.py
Restart=on-failure
Environment=PYTHONUNBUFFERED=1
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$SERVICE_NAME"
  sudo systemctl restart "$SERVICE_NAME"
fi

# ── 4. The firmware ──────────────────────────────────────────────────────────

if $do_firmware; then
  flash="$TARGET_DIR/firmware/flash-ledmatrix.sh"
  if [ ! -x "$flash" ]; then
    warn "no $flash; skipping the firmware"
  else
    echo "  Both panels run a patched build of Framework's firmware: stock, a"
    echo "  greyscale frame takes ~170ms to land, and this one ~15ms. The"
    echo "  official build is kept beside it to roll back to. They are flashed"
    echo "  one at a time and verified separately."
    ok=$assume_yes
    if ! $ok; then
      read -rp "  Flash it now? [y/N] " answer || answer=n
      [[ "$answer" =~ ^[Yy] ]] && ok=true
    fi
    if $ok; then
      # The flash script stops and restarts the service itself: it holds both
      # panels' serial ports while it flashes them one at a time.
      sudo "$flash"
    else
      say "skipped; run 'sudo $flash' whenever you like"
    fi
  fi
fi

echo
say "done. The panel is served from $TARGET_DIR; this clone is only the source."
$do_service && say "watch it with: journalctl -u $SERVICE_NAME -f"
exit 0
