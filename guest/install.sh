#!/bin/bash
# Install Arch Linux ARM onto a blank disk from the Archboot live environment,
# then turn it into a Vagrant base box with prep-guest.sh.
#
# Runs as root inside Archboot (build-box.sh copies it in over the serial
# console). Expects prep-guest.sh next to it. The disk is wiped.
#
# Settings (environment variables):
#   DISK           target disk               (default: /dev/vda)
#   HOSTNAME_      hostname of the box       (default: arch)
#   TIMEZONE       zoneinfo name             (default: Europe/Lisbon)
#   LOCALE         locale to generate        (default: en_US.UTF-8)
#   ROOT_PASSWORD  root password             (default: root)

set -euo pipefail

DISK="${DISK:-/dev/vda}"
HOSTNAME_="${HOSTNAME_:-arch}"
TIMEZONE="${TIMEZONE:-Europe/Lisbon}"
LOCALE="${LOCALE:-en_US.UTF-8}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { printf '==> %s\n' "$*"; }
die() { printf '==> ERROR: %s\n' "$*" >&2; exit 1; }

# Partition device names: /dev/vda1, but /dev/nvme0n1p1.
part() { if [[ "$DISK" == *[0-9] ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi; }

[[ $EUID -eq 0 ]]              || die "run as root"
[[ -d /sys/firmware/efi ]]     || die "not booted in UEFI mode"
[[ -b "$DISK" ]]               || die "no disk at $DISK"
[[ -f "$HERE/prep-guest.sh" ]] || die "prep-guest.sh must be next to this script"
[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || die "unknown timezone $TIMEZONE"

log "Starting network and pacman keyring"
systemctl start systemd-networkd systemd-resolved pacman-init
for _ in $(seq 1 60); do
  getent hosts archlinux.org >/dev/null && break
  sleep 2
done
getent hosts archlinux.org >/dev/null || die "no network (DNS lookup for archlinux.org failed)"

log "Partitioning $DISK (512M EFI + rest ext4)"
wipefs -aq "$DISK"
printf 'label: gpt\n,512M,U\n,,L\n' | sfdisk -q "$DISK"
udevadm settle
mkfs.fat -F32 "$(part 1)" >/dev/null
mkfs.ext4 -qF "$(part 2)"
mount "$(part 2)" /mnt
mount --mkdir "$(part 1)" /mnt/boot

log "Installing the base system (pacstrap, a few minutes)"
if ! pacstrap -K /mnt base linux archlinuxarm-keyring efibootmgr nano >/root/pacstrap.log 2>&1; then
  tail -30 /root/pacstrap.log
  die "pacstrap failed"
fi
[[ -f /mnt/boot/Image && -f /mnt/boot/initramfs-linux.img ]] || die "kernel or initramfs missing in /boot"
genfstab -U /mnt >> /mnt/etc/fstab

log "Configuring the system"
ROOT_UUID="$(findmnt -no UUID /mnt)"
cat > /mnt/root/configure.sh <<'EOF'
set -euo pipefail
echo "root:$ROOT_PASSWORD" | chpasswd
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
sed -i "s/^#\($LOCALE .*\)/\1/" /etc/locale.gen
locale-gen >/dev/null
echo "LANG=$LOCALE" > /etc/locale.conf
echo "$HOSTNAME_" > /etc/hostname
cp /usr/lib/systemd/network/89-ethernet.network.example /etc/systemd/network/20-ethernet.network
systemctl enable systemd-networkd systemd-resolved
mkinitcpio -P >/root/mkinitcpio.log 2>&1 || { tail -20 /root/mkinitcpio.log; exit 1; }
# Boot the kernel straight from the EFI partition (EFI stub), no bootloader.
efibootmgr --create --disk "$DISK" --part 1 --label "Arch Linux" --loader /Image \
  --unicode "Image root=UUID=$ROOT_UUID rw initrd=\\initramfs-linux.img" >/dev/null
rm -f /root/mkinitcpio.log
EOF
arch-chroot /mnt env ROOT_PASSWORD="$ROOT_PASSWORD" TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" \
  HOSTNAME_="$HOSTNAME_" DISK="$DISK" ROOT_UUID="$ROOT_UUID" bash /root/configure.sh
efibootmgr | grep -q 'Arch Linux' || die "EFI boot entry was not created"

log "Preparing the system as a Vagrant box"
cp "$HERE/prep-guest.sh" /mnt/root/prep-guest.sh
arch-chroot /mnt bash /root/prep-guest.sh
rm -f /mnt/root/configure.sh /mnt/root/prep-guest.sh

log "Unmounting"
sync
umount -R /mnt
log "Install complete"
