# Install — per‑distro

This toolkit needs three NVIDIA components:

- the **kernel module + CUDA driver** (the **closed** module if you need `gsp-off.sh` — see your distro below)
- **`nvidia-persistenced`** daemon (keeps the eGPU warm between CUDA calls)
- the **CUDA toolkit** (for `nvcc`, optional but recommended)

The toolkit's `scripts/setup-compute.sh` then drops the modprobe blacklists, udev rule, systemd drop‑in, and regenerates the initramfs — all distro‑agnostic.

## Fedora 44+

**Automated:** `./install.sh` (add `--with-cuda-toolkit` for `nvcc`) does every
step below. The manual path, and why each step is needed:

Use the **closed** module from **RPM Fusion**. If you plan to disable the GSP
(`gsp-off.sh`, the documented fix for GSP init failures on an AMD USB4 host),
the closed module is mandatory: the open one ignores
`NVreg_EnableGpuFirmware=0`. Since branch 615, NVIDIA's CUDA repository ships
the open module only (*"The proprietary kernel modules have been removed"*,
615 installation guide §4.1), so it can no longer be used for the driver.

```bash
# 1. Force the closed module BEFORE installing. akmod-nvidia ships both
#    flavours but picks one at build time: its nvidia-kmod-noopen-checks
#    script switches to the open module for every Turing+ GPU (RTX 20xx+).
echo '%_without_kmod_nvidia_detect 1' | sudo tee /etc/rpm/macros.nvidia-kmod-closed

# 2. Driver + CUDA userspace (libcuda, nvidia-smi, nvidia-persistenced)
sudo dnf install -y "kernel-devel-$(uname -r)" akmod-nvidia xorg-x11-drv-nvidia-cuda

# 3. Build for every installed kernel, then install the RPM akmods produced.
#    akmods can print "Successful" while dnf answered "available but not
#    installed", and a rebuilt kmod has the same version as an existing one.
for k in $(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n'); do
    sudo akmods --force --rebuild --akmod nvidia --kernels "$k"
    sudo dnf reinstall -y /var/cache/akmods/nvidia/kmod-nvidia-"$k"-*.rpm \
      || sudo dnf install -y /var/cache/akmods/nvidia/kmod-nvidia-"$k"-*.rpm
done

# 4. Check: must print "NVIDIA" (closed), not "Dual MIT/GPL" (open)
modinfo -F license /lib/modules/$(uname -r)/extra/nvidia/nvidia.ko*
```

A closed kmod RPM weighs ~88 MB, an open one ~10 MB (the closed one carries
NVIDIA's binary blob).

**CUDA toolkit** (`nvcc`, needed by `egpu-stress.sh install` together with
`cmake`): take it from NVIDIA's repo, with its driver packages excluded so it
cannot pull a conflicting driver:

```bash
sudo dnf config-manager addrepo --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora$(rpm -E %fedora)/x86_64/cuda-fedora$(rpm -E %fedora).repo
sudo dnf config-manager setopt "cuda-fedora$(rpm -E %fedora)-x86_64.excludepkgs=nvidia-*,kmod-nvidia*,dkms-nvidia*,libnvidia*,xorg-x11-nvidia*"
sudo dnf install -y cuda-toolkit cmake
```

Notes:
- RPM Fusion always installs the display package `xorg-x11-drv-nvidia` (it
  provides `nvidia-kmod-common`, which the kmods require). Compute-only mode
  comes from the `nvidia-drm` / `nvidia-modeset` blacklist that
  `setup-compute.sh` installs, not from leaving that package out.
- `nvidia-settings` is a hard dependency too, and GNOME autostarts it at every
  login (it fails without the eGPU). Hide it per user with
  `~/.config/autostart/nvidia-settings-user.desktop` containing `Hidden=true`.
- Disable `nvidia-powerd` (it crashes on a TB/USB4 eGPU):
  `sudo systemctl disable --now nvidia-powerd`.
- Coming from NVIDIA's CUDA repo driver? Remove its driver packages first
  (`nvidia-driver*`, `kmod-nvidia*`, `libnvidia*`).

## Ubuntu 24.04+

Set up NVIDIA's CUDA repo (see [the official guide](https://developer.nvidia.com/cuda-downloads)), then:
```bash
sudo apt install nvidia-driver-cuda nvidia-persistenced cuda-toolkit
```

## Arch / Manjaro

```bash
sudo pacman -S nvidia-open nvidia-utils nvidia-persistenced cuda
```

Notes:
- `nvidia-open` is the open kernel module, recommended for Turing+ (RTX 20xx and later). Use `nvidia-dkms` for older cards.
- Arch ships `nvidia-utils` as the package containing `nvidia-smi`.

## Apply the compute-only configuration

After the packages are installed:

```bash
git clone https://github.com/quazardous/amd-usb4-egpu-toolkit
cd amd-usb4-egpu-toolkit
./scripts/setup-compute.sh           # interactive, asks before each sudo write
./scripts/setup-compute.sh --yes     # non-interactive
```

What it does (all idempotent):

- writes `/etc/modprobe.d/blacklist-nouveau.conf`
- writes `/etc/modprobe.d/nvidia-compute-only.conf` (blacklist `nvidia-drm` + `nvidia-modeset`)
- writes `/etc/udev/rules.d/99-nvidia-egpu-persistenced.rules` (auto start/stop on PCI add/remove)
- writes `/etc/systemd/system/nvidia-persistenced.service.d/override.conf` (eGPU‑aware drop‑in)
- writes `/etc/systemd/system/nvidia-egpu-shutdown.service` + `/usr/local/lib/amd-usb4-egpu-toolkit/shutdown-helper.sh` (avoids shutdown freezes)
- `systemctl daemon-reload` + `udevadm control --reload`
- enables `nvidia-egpu-shutdown.service`
- regenerates initramfs — auto‑detects `dracut` / `update-initramfs` / `mkinitcpio`
- prints the kernel‑cmdline instructions specific to your bootloader

To revert: `./scripts/setup-compute.sh --uninstall`.

## Add the kernel command line argument

`nvidia-drm.modeset=0` is defense‑in‑depth — even if `nvidia-drm` somehow loads (e.g. you re‑run a video‑mode driver install and forget to re‑apply the blacklist), this kernel arg prevents it from grabbing modesetting.

**Fedora / RHEL / openSUSE** (grubby):
```bash
sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=0"
```

**Debian / Ubuntu** (GRUB):
```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=0"/' /etc/default/grub
sudo update-grub
```

**Arch / Manjaro** (GRUB):
```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 nvidia-drm.modeset=0"/' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

**systemd-boot**:
Edit `/boot/loader/entries/*.conf`, append ` nvidia-drm.modeset=0` to the `options` line.

## Reboot

```bash
sudo reboot
```

After reboot, you should have:
- nouveau blacklisted (confirm: `lsmod | grep nouveau` returns empty)
- `nvidia-drm` / `nvidia-modeset` not loaded even after the eGPU is plugged
- udev rule in place (confirm: `ls /etc/udev/rules.d/99-nvidia-egpu-persistenced.rules`)
- `nvidia-persistenced` enabled but inactive until the eGPU is plugged (confirm: `systemctl status nvidia-persistenced` shows `inactive (dead)` cleanly with the condition message, not a `failed` state)

Next: follow [docs/procedure.md](procedure.md) to plug the eGPU.
