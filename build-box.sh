#!/bin/bash
# Build the Arch Linux ARM Vagrant box for UTM, start to finish, unattended.
#
#   1. Download the latest Archboot aarch64 ISO (or use --iso) and verify it
#   2. Create a temporary headless UTM VM with a TCP serial console
#   3. Boot Archboot and run guest/install.sh over the serial console
#   4. Package the VM with package-box.sh and add it to Vagrant
#   5. Delete the temporary VM
#
# Usage: build-box.sh [options]
#   --iso FILE          use this Archboot ISO instead of downloading
#   -n, --name NAME     box name to register   (default: local/arch)
#   -o, --output FILE   .box file to write     (default: <this dir>/arch.box)
#   --disk MIB          box disk size          (default: 16384)
#   --no-add            write the .box but don't `vagrant box add` it
#   --keep-vm           keep the build VM in UTM afterwards
#
# Guest settings can be overridden with environment variables:
#   HOSTNAME_ (arch), TIMEZONE (Europe/Lisbon), LOCALE (en_US.UTF-8),
#   ROOT_PASSWORD (root)

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/.cache"
UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"
ARCHBOOT_URL="https://release.archboot.com/aarch64/latest"

ISO=""
BOX_NAME="local/arch"
OUTPUT="$HERE/arch.box"
DISK_MIB=16384
ADD=1
KEEP_VM=0

usage() { sed -n '2,21p' "$0"; }
while (( $# )); do
  case "$1" in
    --iso)       ISO="$2"; shift 2 ;;
    -n|--name)   BOX_NAME="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    --disk)      DISK_MIB="$2"; shift 2 ;;
    --no-add)    ADD=0; shift ;;
    --keep-vm)   KEEP_VM=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '\n### %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -x "$UTMCTL" ]] || die "UTM is not installed in /Applications"
command -v vagrant >/dev/null || (( ! ADD )) || die "vagrant not found"
mkdir -p "$CACHE"
STAMP="$(date +%Y%m%d-%H%M%S)"
CONSOLE_LOG="$CACHE/build-$STAMP.log"

# --- 1. ISO ------------------------------------------------------------------

blake2b() { python3 -I -c 'import hashlib,sys
h=hashlib.blake2b()
with open(sys.argv[1],"rb") as f:
    for c in iter(lambda: f.read(1<<20), b""): h.update(c)
print(h.hexdigest())' "$1"; }

if [[ -z "$ISO" ]]; then
  log "Finding the latest Archboot aarch64 ISO"
  ISO_NAME="$(curl -fsSL "$ARCHBOOT_URL/iso/" \
    | grep -oE 'archboot-[0-9.]+-[0-9.]+-[^"/]*-aarch64-ARCH-aarch64\.iso' | sort -u | tail -1)"
  [[ -n "$ISO_NAME" ]] || die "couldn't find an ISO at $ARCHBOOT_URL/iso/"
  ISO="$CACHE/$ISO_NAME"
  EXPECTED="$(curl -fsSL "$ARCHBOOT_URL/b2sum.txt" | grep -F "(iso/$ISO_NAME) =" | awk '{print $NF}')"
  [[ -n "$EXPECTED" ]] || die "no checksum for $ISO_NAME in b2sum.txt"
  if [[ -f "$ISO" && "$(blake2b "$ISO")" == "$EXPECTED" ]]; then
    echo "Using cached $ISO_NAME"
  else
    echo "Downloading $ISO_NAME"
    curl -fL --progress-bar -o "$ISO.part" "$ARCHBOOT_URL/iso/$ISO_NAME"
    [[ "$(blake2b "$ISO.part")" == "$EXPECTED" ]] || { rm -f "$ISO.part"; die "checksum mismatch for $ISO_NAME"; }
    mv "$ISO.part" "$ISO"
    find "$CACHE" -name 'archboot-*.iso' ! -name "$ISO_NAME" -delete   # drop older ISOs
  fi
  echo "Checksum OK (BLAKE2b)"
fi
[[ -f "$ISO" ]] || die "ISO not found: $ISO"
ISO="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"

# --- 2. Build VM -------------------------------------------------------------

PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
VM_NAME="arch-box-build-$STAMP"
VM_ID=""
SUCCESS=0

cleanup() {
  [[ -n "$VM_ID" ]] || return 0
  if [[ "$("$UTMCTL" status "$VM_ID" 2>/dev/null)" != stopped ]]; then
    "$UTMCTL" stop "$VM_ID" --force >/dev/null 2>&1 || true
    sleep 3
  fi
  if (( SUCCESS && ! KEEP_VM )); then
    osascript -e "tell application \"UTM\" to delete virtual machine id \"$VM_ID\"" >/dev/null \
      && echo "Deleted build VM $VM_NAME"
  else
    echo "Build VM kept in UTM: $VM_NAME ($VM_ID)"
  fi
}
trap cleanup EXIT

log "Creating build VM $VM_NAME (serial console on 127.0.0.1:$PORT)"
# «class SrPt» is the configuration's "serial ports" property; spelled out,
# AppleScript confuses it with UTM's "serial port" class.
VM_ID="$(osascript - "$ISO" "$VM_NAME" "$PORT" "$DISK_MIB" <<'OSA'
on run argv
	set iso to POSIX file (item 1 of argv)
	with timeout of 300 seconds
		tell application "UTM"
			set vm to make new virtual machine with properties {backend:qemu, configuration:{name:(item 2 of argv), architecture:"aarch64", memory:2048, cpu cores:2, icon:"arch-linux", notes:"Temporary VM made by build-box.sh", drives:{{removable:true, source:iso}, {guest size:((item 4 of argv) as integer)}}, network interfaces:{{mode:shared}, {mode:emulated}}, «class SrPt»:{{interface:tcp, port:((item 3 of argv) as integer)}}, displays:{}}}
			return id of vm
		end tell
	end timeout
end run
OSA
)"
[[ -n "$VM_ID" ]] || die "UTM didn't return a VM id"
echo "VM id: $VM_ID"

# --- 3. Install over the serial console --------------------------------------

log "Installing Arch Linux (console log: $CONSOLE_LOG)"
"$UTMCTL" start "$VM_ID"
python3 -I "$HERE/lib/console.py" --port "$PORT" --log "$CONSOLE_LOG" \
  --put "$HERE/guest/install.sh=/root/install.sh" \
  --put "$HERE/guest/prep-guest.sh=/root/prep-guest.sh" \
  --run "DISK=/dev/vda HOSTNAME_='${HOSTNAME_:-arch}' TIMEZONE='${TIMEZONE:-Europe/Lisbon}' LOCALE='${LOCALE:-en_US.UTF-8}' ROOT_PASSWORD='${ROOT_PASSWORD:-root}' bash /root/install.sh" \
  --poweroff \
  || die "installation failed; see $CONSOLE_LOG"

echo "Waiting for the VM to power off"
for _ in $(seq 1 90); do
  [[ "$("$UTMCTL" status "$VM_ID" 2>/dev/null)" == stopped ]] && break
  sleep 2
done
[[ "$("$UTMCTL" status "$VM_ID")" == stopped ]] || die "VM didn't power off"

# The ISO drive would make the box point at a file on this Mac.
osascript - "$VM_ID" <<'OSA' >/dev/null
on run argv
	tell application "UTM"
		set vm to virtual machine id (item 1 of argv)
		set c to configuration of vm
		set keep to {}
		repeat with d in drives of c
			if removable of d is false then set end of keep to contents of d
		end repeat
		set drives of c to keep
		update configuration of vm with c
	end tell
end run
OSA
echo "Removed the ISO drive"

# --- 4. Package --------------------------------------------------------------

log "Packaging"
PKG_ARGS=(-n "$BOX_NAME" -o "$OUTPUT")
(( ADD )) || PKG_ARGS+=(--no-add)
"$HERE/package-box.sh" "$VM_ID" "${PKG_ARGS[@]}"

SUCCESS=1
log "Done: $BOX_NAME"
