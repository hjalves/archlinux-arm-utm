#!/bin/bash
# Prepare an installed Arch Linux ARM system to become a Vagrant (UTM) base box.
#
# Run as root, as the LAST step before packaging, either:
#   - inside `arch-chroot -S /mnt` at the end of the install in "arch vm.txt", or
#   - on the installed system after booting it (add --poweroff to shut down at the end).
#
# After this script runs, do NOT boot the VM again before packaging it: the
# first boot would regenerate /etc/machine-id and the SSH host keys, and every
# VM made from the box would share them (and get the same DHCP address).
#
# Usage: prep-guest.sh [--poweroff]

set -euo pipefail

POWEROFF=0
for arg in "$@"; do
  case "$arg" in
    --poweroff) POWEROFF=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f /etc/arch-release ]] || { echo "this does not look like Arch Linux" >&2; exit 1; }

log() { printf '\n==> %s\n' "$*"; }

# Vagrant's well-known insecure public keys (from Vagrant 2.4.9's keys/vagrant.pub).
# Vagrant logs in with these on the first `vagrant up`, then replaces them with
# a fresh per-machine key.
VAGRANT_PUBKEYS='ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1YdxBpNlzxDqfJyw/QKow1F+wvG9hXGoqiysfJOn5Y vagrant insecure public key'

log "Installing packages (openssh, sudo, inetutils)"
# inetutils provides `hostname`, which base Arch lacks and many scripts expect.
pacman -Syu --noconfirm --needed openssh sudo inetutils

# The UTM plugin checks for the QEMU guest agent on `vagrant up` and only warns
# if it is missing, so a failure here is not fatal.
if pacman -S --noconfirm --needed qemu-guest-agent; then
  # The unit is started by udev when the agent channel exists; enabling may be a no-op.
  systemctl enable qemu-guest-agent.service 2>/dev/null || true
else
  echo "warning: could not install qemu-guest-agent; vagrant up will print a warning" >&2
fi

log "Enabling sshd, networking and package-cache cleanup"
# paccache.timer (pacman-contrib, installed by pacstrap) trims the package cache weekly.
systemctl enable sshd.service systemd-networkd.service systemd-resolved.service paccache.timer

# DHCP on every Ethernet card. The box has two (Shared + Emulated VLAN) and
# both need an address.
if ! compgen -G '/etc/systemd/network/*.network' >/dev/null; then
  cp /usr/lib/systemd/network/89-ethernet.network.example /etc/systemd/network/20-ethernet.network
  echo "created /etc/systemd/network/20-ethernet.network"
fi
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

log "Creating the vagrant user"
if ! id vagrant &>/dev/null; then
  useradd -m -G wheel -s /bin/bash vagrant
fi
usermod -aG wheel vagrant
echo 'vagrant:vagrant' | chpasswd

install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh
printf '%s\n' "$VAGRANT_PUBKEYS" > /home/vagrant/.ssh/authorized_keys
chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
chmod 600 /home/vagrant/.ssh/authorized_keys

log "Allowing passwordless sudo for vagrant"
SUDOERS=/etc/sudoers.d/10-vagrant
printf 'vagrant ALL=(ALL) NOPASSWD: ALL\nDefaults:vagrant !requiretty\n' > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp" >/dev/null
mv "$SUDOERS.tmp" "$SUDOERS"

log "Cleaning up so every VM from this box is unique"
pacman -Scc --noconfirm >/dev/null || true
rm -f /etc/ssh/ssh_host_*          # regenerated at boot by sshdgenkeys.service
: > /etc/machine-id                # empty file = regenerated on first boot
rm -f /var/lib/dbus/machine-id
rm -rf /var/lib/systemd/network/* 2>/dev/null || true
rm -f /root/.bash_history /home/vagrant/.bash_history
journalctl --rotate &>/dev/null && journalctl --vacuum-time=1s &>/dev/null || true

log "Done"
echo "The system is ready to be packaged. Power off and don't boot it again before packaging."
echo "Next, on the Mac: package-box.sh <UTM VM name>"

if (( POWEROFF )); then
  if systemd-detect-virt --chroot &>/dev/null; then
    echo "(in a chroot: --poweroff ignored; exit the chroot, unmount, then poweroff)"
  else
    sync; systemctl poweroff
  fi
fi
