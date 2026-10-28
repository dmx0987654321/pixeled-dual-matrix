#!/usr/bin/env bash
# Flash firmware onto both Framework 16 LED matrices, over USB, with no
# unplugging.
#
#   sudo firmware/flash-ledmatrix.sh                       the pixeled build
#   sudo firmware/flash-ledmatrix.sh ledmatrix-0.2.0-official.uf2   roll back
#
# The script identifies both matrices by USB vendor/product ID and stable
# udev ID_PATH, then flashes them one at a time. ttyACM numbering may change
# as each matrix reboots, so /dev/ttyACM0 and /dev/ttyACM1 are never assumed.
# Each RPI-RP2 bootloader drive is handled alone; if another RP2040 is already
# in bootloader mode, the script stops rather than risk flashing the wrong one.
#
# If a flash leaves a matrix unresponsive, the bootloader lives in the chip's
# ROM and cannot be overwritten: unplug that module, flip DIP2 on, plug it back
# in, and run this again with the official .uf2. Flip DIP2 off afterwards.
set -euo pipefail

SERVICE="pixeled.service"
MATRIX_ID="32ac:0020"
BOOT_LABEL="RPI-RP2"
EXPECTED_MATRICES=2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UF2="${1:-$SCRIPT_DIR/ledmatrix-0.2.0-pixeled.uf2}"

die() { echo "✗ $*" >&2; exit 1; }
say() { echo "• $*"; }

[ "$EUID" -eq 0 ] || die "run with sudo: mounting the bootloader drive needs root"
[ "$#" -le 1 ] || die "usage: ${0##*/} [firmware.uf2]"

# ── Checks before touching anything ──────────────────────────────────────────

[ -f "$UF2" ] || die "no such file: $UF2"
size=$(stat -c %s "$UF2")
# Every UF2 block is 512 bytes and opens with the same 8-byte magic.
magic=$(head -c 8 "$UF2" | od -An -tx1 | tr -d ' \n')
[ "$magic" = "5546320a57515d9e" ] || die "$UF2 is not a UF2 file"
[ $((size % 512)) -eq 0 ] || die "$UF2 is truncated ($size bytes)"
# Family ID at offset 28 of the first block: RP2040 is 0xe48bff56.
family=$(od -An -tx4 -j 28 -N 4 --endian=little "$UF2" | tr -d ' ')
[ "$family" = "e48bff56" ] || die "$UF2 is not RP2040 firmware (family 0x$family)"

matrix_paths() {
  local dev props path
  for dev in /dev/ttyACM*; do
    [ -e "$dev" ] || continue
    props=$(udevadm info -q property -n "$dev" 2>/dev/null) || continue
    if grep -qx "ID_VENDOR_ID=${MATRIX_ID%:*}" <<<"$props" \
        && grep -qx "ID_MODEL_ID=${MATRIX_ID#*:}" <<<"$props"; then
      path=$(sed -n 's/^ID_PATH=//p' <<<"$props")
      [ -n "$path" ] || die "could not determine stable USB ID_PATH for $dev"
      printf '%s\n' "$path"
    fi
  done
}

matrix_tty_for_path() {
  local wanted=$1 dev props path
  for dev in /dev/ttyACM*; do
    [ -e "$dev" ] || continue
    props=$(udevadm info -q property -n "$dev" 2>/dev/null) || continue
    grep -qx "ID_VENDOR_ID=${MATRIX_ID%:*}" <<<"$props" || continue
    grep -qx "ID_MODEL_ID=${MATRIX_ID#*:}" <<<"$props" || continue
    path=$(sed -n 's/^ID_PATH=//p' <<<"$props")
    if [ "$path" = "$wanted" ]; then
      echo "$dev"
      return 0
    fi
  done
  return 1
}

boot_drives() {
  lsblk -rno NAME,LABEL | awk -v l="$BOOT_LABEL" '$2 == l { print "/dev/" $1 }'
}

boot_drive_count() {
  boot_drives | awk 'END { print NR + 0 }'
}

no_boot_drives() { [ "$(boot_drive_count)" -eq 0 ]; }

one_boot_drive() { [ "$(boot_drive_count)" -eq 1 ]; }

wait_for() {  # seconds, then a command that succeeds once the wait is over
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.25
  done
}

flash_one() {
  local index=$1 path=$2 tty drive reply major minor_patch pre version

  tty=$(matrix_tty_for_path "$path") \
    || die "matrix $index/$EXPECTED_MATRICES at $path is not present"
  say "matrix $index/$EXPECTED_MATRICES is $tty ($path); requesting bootloader"
  stty -F "$tty" 115200 raw -echo
  printf '\x32\xac\x02' > "$tty"

  say "waiting for this matrix's $BOOT_LABEL drive"
  wait_for 20 one_boot_drive \
    || die "expected exactly one $BOOT_LABEL drive after reboot, found $(boot_drive_count)"
  drive=$(boot_drives)
  say "bootloader drive is $drive"

  # The desktop may auto-mount the drive at the same time; mounting it here as
  # well is harmless, and doesn't depend on whether or where that happened.
  mnt=$(mktemp -d /tmp/rpi-rp2.XXXXXX)
  wait_for 5 mount "$drive" "$mnt" || die "could not mount $drive"
  [ -f "$mnt/INFO_UF2.TXT" ] || die "$drive does not look like an RP2040 bootloader drive"
  sed 's/^/    /' "$mnt/INFO_UF2.TXT"

  say "copying $(basename "$UF2") ($size bytes) to matrix $index/$EXPECTED_MATRICES"
  # The bootloader reboots as soon as it has the last block, which can pull the
  # drive out from under sync - so a failure here is not yet a failed flash.
  cp "$UF2" "$mnt/" && sync || true
  umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
  rmdir "$mnt" 2>/dev/null || true
  mnt=""

  say "waiting for matrix $index/$EXPECTED_MATRICES to return"
  wait_for 30 matrix_tty_for_path "$path" >/dev/null \
    || die "matrix at $path did not come back within 30s - see the recovery note"
  wait_for 10 no_boot_drives \
    || die "a $BOOT_LABEL drive remained after flashing matrix $index"
  tty=$(matrix_tty_for_path "$path")
  sleep 1   # let it finish enumerating before talking to it

  stty -F "$tty" 115200 raw -echo
  exec 3<>"$tty"
  printf '\x32\xac\x20' >&3
  reply=$(timeout 3 head -c 32 <&3 | od -An -tu1 -w32) || true
  exec 3>&-

  read -r -a version_bytes <<<"$reply" || true
  if [ "${#version_bytes[@]}" -ne 32 ]; then
    die "matrix at $path returned on $tty but did not answer the version query"
  fi
  major=${version_bytes[0]}
  minor_patch=${version_bytes[1]}
  pre=${version_bytes[2]}
  version="$major.$((minor_patch >> 4)).$((minor_patch & 15))"
  if [ "$pre" = "1" ]; then
    say "matrix $index/$EXPECTED_MATRICES verified: firmware $version, pixeled build"
  else
    say "matrix $index/$EXPECTED_MATRICES verified: firmware $version, official build"
  fi
}

# ── Stop the service, and put it back however this exits ─────────────────────

was_active=false
if systemctl is-active --quiet "$SERVICE"; then
  was_active=true
  say "stopping $SERVICE"
  systemctl stop "$SERVICE"
fi

mnt=""
cleanup() {
  if [ -n "$mnt" ]; then
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
  fi
  if $was_active; then
    say "starting $SERVICE again"
    systemctl start "$SERVICE" || echo "✗ could not restart $SERVICE" >&2
  fi
}
trap cleanup EXIT

# ── Confirm both normal-mode matrices before flashing either ─────────────────

mapfile -t paths < <(matrix_paths)
[ "${#paths[@]}" -eq "$EXPECTED_MATRICES" ] \
  || die "expected $EXPECTED_MATRICES LED matrices (USB $MATRIX_ID), found ${#paths[@]}"
if [ "${paths[0]}" = "${paths[1]}" ]; then
  die "both matrices resolved to the same USB ID_PATH"
fi
no_boot_drives \
  || die "a $BOOT_LABEL drive is already present; take any RP2040 out of bootloader mode before flashing"

say "flashing both matrices one at a time"
flash_one 1 "${paths[0]}"
flash_one 2 "${paths[1]}"
say "both LED matrices flashed and verified"
