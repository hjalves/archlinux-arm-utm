#!/bin/bash
# Package a stopped UTM VM as a Vagrant box for the vagrant_utm provider and
# add it to Vagrant.
#
# Usage: package-box.sh <UTM VM name or UUID | path/to/VM.utm> [options]
#   -n, --name NAME     box name to register (default: local/arch)
#   -o, --output FILE   .box file to write  (default: ./arch.box)
#       --no-add        only write the .box file, don't run `vagrant box add`
#
# The VM must be shut down, and its first two network cards must be
# "Shared Network" then "Emulated VLAN" (the plugin requires this).

set -euo pipefail

usage() { sed -n '2,11p' "$0"; }

BOX_NAME="local/arch"
OUTPUT="./arch.box"
ADD=1
VM=""

while (( $# )); do
  case "$1" in
    -n|--name)   BOX_NAME="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    --no-add)    ADD=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)           [[ -z "$VM" ]] || { echo "only one VM, please" >&2; exit 2; }; VM="$1"; shift ;;
  esac
done
[[ -n "$VM" ]] || { usage >&2; exit 2; }

UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

STAGE="$(mktemp -d -t utm-box)"
trap 'rm -rf "$STAGE"' EXIT

if [[ -d "$VM" && "$VM" == *.utm ]]; then
  # A .utm bundle on disk: copy it (APFS clone is instant and takes no space).
  SRC="${VM%/}"
  [[ -f "$SRC/config.plist" ]] || { echo "$SRC has no config.plist; not a UTM VM?" >&2; exit 1; }
  echo "==> VM bundle: $SRC"
  cp -cR "$SRC" "$STAGE/box.utm" 2>/dev/null || cp -R "$SRC" "$STAGE/box.utm"
else
  # A VM registered in UTM (name or UUID). UTM's own folder is protected by
  # macOS, so ask UTM to export it rather than reading it directly.
  [[ -x "$UTMCTL" ]] || { echo "UTM not found in /Applications" >&2; exit 1; }
  STATUS="$("$UTMCTL" status "$VM" 2>/dev/null || true)"
  [[ -n "$STATUS" ]] || { echo "UTM has no VM called '$VM' (see: utmctl list)" >&2; exit 1; }
  [[ "$STATUS" == *stopped* ]] || { echo "VM '$VM' is '$STATUS'; shut it down first" >&2; exit 1; }
  echo "==> Exporting '$VM' from UTM"
  osascript - "$VM" "$STAGE/box.utm" <<'OSA'
on run argv
	set vmRef to item 1 of argv
	with timeout of 1800 seconds
		tell application "UTM"
			try
				set vm to virtual machine id vmRef
				get name of vm
			on error
				set vm to virtual machine named vmRef
			end try
			export vm to (POSIX file (item 2 of argv))
		end tell
	end timeout
end run
OSA
  [[ -f "$STAGE/box.utm/config.plist" ]] || { echo "export failed" >&2; exit 1; }
fi
SRC="$STAGE/box.utm"

# Give the boxed VM its own name. UTM renames a VM's folder to match its name
# when the plugin first saves it, so a box still named like the template VM
# fails on `vagrant up` with "an item with the same name already exists".
BOXED_NAME="vagrant-box-$(date +%Y%m%d%H%M%S)"
plutil -replace Information.Name -string "$BOXED_NAME" "$SRC/config.plist"
echo "==> Boxed VM name: $BOXED_NAME"

# Check the settings the plugin depends on.
plutil -convert json -o - "$SRC/config.plist" | python3 -I -c '
import json, sys
c = json.load(sys.stdin)
errors, warnings = [], []
if c.get("Backend") not in (None, "QEMU"):
    errors.append("backend is %r; vagrant_utm needs a QEMU VM (UTM: Virtualize, not Apple Virtualization)" % c.get("Backend"))
net = c.get("Network") or []
modes = [n.get("Mode") for n in net]
if len(modes) < 2 or modes[0] != "Shared" or modes[1] != "Emulated":
    errors.append("network cards are %s; need [Shared, Emulated] as the first two" % modes)
if c.get("Display"):
    warnings.append("VM has a display, so UTM opens a window on vagrant up (remove it and add a Pseudo-TTY serial port for headless)")
for w in warnings: print("warning:", w, file=sys.stderr)
for e in errors: print("error:", e, file=sys.stderr)
sys.exit(1 if errors else 0)
'
echo "==> Settings OK"

echo '{"architecture":"arm64","provider":"utm"}' > "$STAGE/metadata.json"
cat > "$STAGE/Vagrantfile" <<'EOF'
# Defaults shipped inside the box; a project Vagrantfile overrides these.
Vagrant.configure("2") do |config|
  config.ssh.username = "vagrant"
end
EOF

mkdir -p "$(dirname "$OUTPUT")"
echo "==> Writing $OUTPUT"
tar -cf "$OUTPUT" -C "$STAGE" metadata.json Vagrantfile box.utm
ls -lh "$OUTPUT" | awk '{print "    " $5}'

if (( ADD )); then
  echo "==> Adding box as $BOX_NAME"
  vagrant box add --force --name "$BOX_NAME" "$OUTPUT"
  echo "Done. Use it with:  config.vm.box = \"$BOX_NAME\""
else
  echo "Done. Add it with:  vagrant box add --name $BOX_NAME $OUTPUT"
fi
