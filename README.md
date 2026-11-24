# Arch Linux ARM box for Vagrant + UTM

No public Arch arm64 box exists for the `vagrant_utm` provider, so this folder builds one
from scratch with Archboot, unattended:

```bash
./build-box.sh
```

About 10 minutes later you have `arch.box`, registered with Vagrant as `local/arch`.

The [claude-sandbox](https://github.com/hjalves/claude-sandbox) VM is built on this box.

Requires: UTM 5 in `/Applications`, Vagrant with the `vagrant_utm` plugin (0.2.0+), and
Python 3. Tested with UTM 5.0.8, Vagrant 2.4.9, vagrant_utm 0.2.0 and Archboot 7.3.4-2.

## What `build-box.sh` does

1. **ISO**: downloads the latest Archboot aarch64 ISO into `.cache/` and checks its
   BLAKE2b sum against Archboot's `b2sum.txt`. A cached ISO is reused while it's still the
   latest version. Use `--iso FILE` to supply your own.
2. **Build VM**: has UTM (through AppleScript) create a temporary headless VM,
   `arch-box-build-<timestamp>`: 2 CPUs, 2 GB RAM, the disk (`--disk`, 16 GB by default),
   a Shared and an Emulated VLAN network card, and a serial console on a free localhost
   TCP port.
3. **Install**: boots Archboot. `lib/console.py` drives the serial console: it opens a
   shell, copies `guest/install.sh` and `guest/prep-guest.sh` in (checking their hashes),
   and runs the install. Progress lines are echoed; the full console output goes to
   `.cache/build-<timestamp>.log`.
4. **Package**: powers off, removes the ISO drive, and runs `package-box.sh`.
5. **Clean up**: deletes the build VM. If the build fails, the VM is kept for debugging;
   pass `--keep-vm` to keep it after a successful build too.

Options: `--iso FILE`, `-n/--name` (box name), `-o/--output` (.box path), `--disk MIB`,
`--no-add`, `--keep-vm`. Guest settings come from environment variables: `HOSTNAME_`
(`arch`), `TIMEZONE` (`Europe/Lisbon`), `LOCALE` (`en_US.UTF-8`), `ROOT_PASSWORD` (`root`).

## Files

| File | Runs on | What it does |
|---|---|---|
| `build-box.sh` | Mac | The whole build, as above |
| `lib/console.py` | Mac | Serial console driver: waits for the boot prompt, copies files in, runs a command, returns its exit code |
| `guest/install.sh` | Archboot | Partitions the disk (512 MB EFI + ext4), runs `pacstrap`, configures locale, timezone, hostname and networkd, creates an EFI-stub boot entry, then runs `prep-guest.sh` in the chroot |
| `guest/prep-guest.sh` | new system | Adds the `vagrant` user with Vagrant's insecure key, passwordless sudo, sshd and the QEMU guest agent. Then clears machine-id and SSH host keys so each VM is unique |
| `package-box.sh` | Mac | Exports a stopped UTM VM, gives it a unique name and UUID, checks the network cards, writes the `.box` and runs `vagrant box add` |
| `Vagrantfile` | Mac | A minimal machine using `local/arch` |
| `lib/port_check_fix.rb` | Mac | Fixes Vagrant's forwarded-port collision check on this macOS (see Troubleshooting) |

`package-box.sh` also works on its own, for a VM you set up by hand:
`./package-box.sh "<UTM VM name or UUID>"`. The VM must be stopped, and its first two
network cards must be Shared Network, then Emulated VLAN.

## Use the box

```bash
vagrant up
vagrant ssh
```

The `/vagrant` synced folder is disabled in the `Vagrantfile` until VirtFS has been checked
with this box. The root password is `root` unless you set `ROOT_PASSWORD`. That's fine for a
local VM, but change it before the box goes anywhere else.

## Troubleshooting

- **Build fails**: read `.cache/build-*.log`. The build VM stays in UTM; delete it there when
  you're done.
- **"an item with the same name already exists" on `vagrant up`**: the box was packaged with
  the same internal name as a VM in UTM. `package-box.sh` now prevents this. Rebuild.
- **Every VM gets SSH port 2250, and a second VM fails with "Could not set up host
  forwarding rule"**: Vagrant 2.4.9's bundled Ruby reports refused ports as open on this
  macOS, so Vagrant thinks 2200–2250 are all taken. The cause is a macOS 26.7+/27 kernel
  change (a retried `connect()` on a refused socket returns `EISCONN`). Ruby fixed it in 3.4+
  but not in the 3.3 that Vagrant bundles; see [Ruby #22223](https://bugs.ruby-lang.org/issues/22223)
  and [Vagrant #13845](https://github.com/hashicorp/vagrant/issues/13845).
  `lib/port_check_fix.rb` replaces the check; the `Vagrantfile` `require_relative`s it, so
  the repo works on any Mac. Copy it into other projects that use the box. To fix
  every project on a machine, put the same code in `~/.vagrant.d/Vagrantfile`, which Vagrant
  loads before each project's Vagrantfile. Remove both once Vagrant ships a fix.
- **First AppleScript call hangs**: macOS may be asking for permission to let your terminal
  control UTM. Allow it in the prompt, or under System Settings → Privacy & Security →
  Automation.
