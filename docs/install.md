# Install — per‑distro

This toolkit needs three NVIDIA components:

- the **kernel module + CUDA driver** (`nvidia-driver-cuda` or distro equivalent — NOT the full display driver)
- **`nvidia-persistenced`** daemon (keeps the eGPU warm between CUDA calls)
- the **CUDA toolkit** (for `nvcc`, optional but recommended)

The toolkit's `scripts/setup-compute.sh` then drops the modprobe blacklists, udev rule, systemd drop‑in, and regenerates the initramfs — all distro‑agnostic.

## Fedora 44+

Use NVIDIA's CUDA repo (latest drivers, more reliable than RPM Fusion for this use case):

```bash
sudo dnf config-manager addrepo --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora$(rpm -E %fedora)/x86_64/cuda-fedora$(rpm -E %fedora).repo
sudo dnf install -y nvidia-driver-cuda nvidia-persistenced cuda-toolkit
```

If you previously installed RPM Fusion NVIDIA packages, remove them to avoid conflicts:
```bash
sudo dnf remove -y akmod-nvidia 'xorg-x11-drv-nvidia*'
```

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
- `systemctl daemon-reload` + `udevadm control --reload`
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
