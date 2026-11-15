# Arch Linux ARM box for Vagrant + UTM

No public Arch arm64 box exists for the `vagrant_utm` provider, so this folder builds one
from a normal Archboot install.

| File | Runs on | What it does |
|---|---|---|
| `prep-guest.sh` | the Arch VM, as root | Adds the `vagrant` user, Vagrant's insecure SSH key, passwordless sudo, sshd, DHCP and the QEMU guest agent, then clears machine-id and SSH host keys |
| `package-box.sh` | the Mac | Checks the stopped UTM VM, tars it into `arch.box` and runs `vagrant box add` |
| `Vagrantfile` | the Mac | Uses the box (`local/arch`) |

Tested with: Vagrant 2.4.9, vagrant_utm 0.2.0, UTM 5.0.8.

## 1. Create the template VM in UTM

1. **Create a New Virtual Machine → Virtualize → Linux**, and boot from
   `../archboot-*-aarch64-ARCH-aarch64.iso`. A 10–20 GB disk is plenty.
2. Before starting it, open the VM's settings:
   - **Network** (first card): mode **Shared Network** (the default).
   - **New… → Network**: mode **Emulated VLAN**. The plugin forwards SSH through this one.

## 2. Install Arch

Follow `../arch vm.txt` up to `arch-chroot`. Before entering the chroot, fetch the prep
script from the Mac. On the Mac:

```bash
python3 -m http.server -d ~/Projects/ClaudeArch/vagrant 8000
```

In the VM (192.168.64.1 is the Mac as seen from UTM's Shared Network):

```bash
curl -o /mnt/root/prep-guest.sh http://192.168.64.1:8000/prep-guest.sh
```

Then do the rest of `arch vm.txt` inside the chroot. Run the script **last**, just before
`exit`:

```bash
bash /root/prep-guest.sh
```

Exit the chroot, unmount, and `poweroff`. **Don't boot the VM again**: the first boot would
recreate the machine-id and SSH host keys, and every VM made from the box would share them.

(You can also boot the installed system once and run `prep-guest.sh --poweroff` there.)

## 3. Make it headless (optional, recommended)

In the VM's settings, remove the **Display** and **Sound** devices and add a **Serial**
device set to **Pseudo-TTY**. Otherwise UTM opens a window on every `vagrant up`.

## 4. Package and add the box

```bash
./package-box.sh "Arch Linux"
```

Use the VM's name (or UUID) as UTM shows it, or the path to a `.utm` bundle. For a VM
registered in UTM, the script asks UTM to export it, because macOS blocks direct access to
UTM's folder. The boxed VM gets a unique internal name (`vagrant-box-<timestamp>`); without
one, `vagrant up` fails with "an item with the same name already exists". This writes
`arch.box` and registers it as `local/arch`. Afterwards you can delete the template VM from
UTM and `arch.box` itself, since Vagrant keeps its own copy.

## 5. Use it

```bash
vagrant up
vagrant ssh
```

The `/vagrant` synced folder is disabled in the `Vagrantfile` until VirtFS is checked with
this box.

The root password is still `root`, from `arch vm.txt`. That's fine for a local VM, but
change it before the box goes anywhere else.
