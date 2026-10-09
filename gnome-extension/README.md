# eGPU Indicator (GNOME Shell extension)

A panel indicator for the eGPU, GNOME Shell 50.

- **Shows up only when an eGPU is plugged in** (or was just ejected).
- Icon: display = OK, warning = something needs attention, eject = safe to unplug.
- Menu: GPU, PCIe link, temperature, load, VRAM, power, `nvidia-persistenced`,
  programs using the GPU.
- **Eject eGPU**: runs `egpu-eject.sh` through `pkexec` (GNOME password
  dialog), then tells you when it is safe to unplug. **Undo eject** brings the
  GPU back without unplugging.

## Safety

The panel icon never touches the NVIDIA driver: it reads sysfs, `ps`,
`systemctl` and the kernel log. `nvidia-smi` runs only while the menu is open,
and only when the driver is bound, no nvidia process is stuck, the link is not
in the Phoenix x1-Gen1 state and no previous call is still running. A call
that times out marks the driver as not responding and stops further calls
(piling up calls on a stuck driver is the NVRM cascade).

Eject runs `/usr/local/lib/amd-usb4-egpu-toolkit/egpu-eject.sh`, a root-owned
copy installed by `scripts/setup-compute.sh` (pkexec must not run a
user-writable file).

By default pkexec asks for your password. To eject without one, install the
polkit rule (admins only, local active session, this one script only):

```bash
./scripts/setup-compute.sh --passwordless-eject     # or: ./install.sh --passwordless-eject
```

Eject refuses while a program holds `/dev/nvidia*`; the menu's "In use by"
names it. Desktop apps are kept off the eGPU by the session environment file
`setup-compute.sh` installs (Vulkan / EGL hidden), effective after a re-login.

## Install

```bash
./install.sh --with-gnome-extension     # or by hand:
ln -s "$PWD/gnome-extension/egpu-indicator@quazardous.github.io" ~/.local/share/gnome-shell/extensions/
# log out and back in, then:
gnome-extensions enable egpu-indicator@quazardous.github.io
```

On Wayland the shell only discovers new extensions at login, so
`gnome-extensions enable` fails until you log back in. Or build the zip
(`./gnome-extension/pack.sh`) and run `gnome-extensions install --force` on it. To try it without logging out,
run a nested session (needs `mutter-devkit`):

```bash
dbus-run-session gnome-shell --devkit --wayland
```

## Publishing

Prepared, not published: see [PUBLISHING.md](PUBLISHING.md) (build with `./pack.sh`).
