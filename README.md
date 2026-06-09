# amd-usb4-egpu-toolkit

NVIDIA eGPU as a **CUDA‑only compute accelerator** on a Linux laptop with an **AMD USB4** host (Phoenix / Hawk Point / Strix family) — Ollama, llama.cpp, ComfyUI, PyTorch.

The eGPU stays headless; the laptop's iGPU keeps driving the screen.

**Validated on:** Lenovo ThinkPad T14s Gen 5 AMD (Ryzen 7 PRO 8840HS, Hawk Point) + Razer Core X V2 (USB4) + NVIDIA RTX 3090.

## What this fixes

Three pain points that other guides cover poorly — see [docs/why.md](docs/why.md) for the full story:

- **AMD Phoenix x1‑Gen1 PCIe tunnel bug** → Xid 79 during driver init
- **NVRM cascade deadlock** after Xid 79 → only reboot recovers
- **Silent driver session loss on idle** without `nvidia-persistenced` → next CUDA call deadlocks

## Hardware compatibility

| Component | Examples |
|---|---|
| Laptop SoC | AMD Ryzen 7xxx/8xxx series with USB4 (Phoenix, Hawk Point, Strix) |
| eGPU enclosure | Razer Core X V2 (USB4), Razer Core X (TB3), Aorus / Akitio / similar |
| eGPU GPU | NVIDIA RTX 30xx / 40xx (open driver), workstation A‑series |
| Distro | Any with systemd + udev (Fedora 44+, Ubuntu 24.04+, Arch) |
| Kernel | 6.6+ recommended |

Should also work on Intel USB4 hosts — the persistence/cascade fixes are vendor‑agnostic. The Phoenix x1‑Gen1 specifically is AMD‑side.

## What's in here

```
scripts/
  egpu-preflight.sh  pre-plug readiness check (config in place, no leftover bad state)
  egpu-diag.sh       passive live diagnostic, never touches the driver
  egpu-stress.sh     deviceQuery + bandwidth + gpu-burn, compute-only safe
  setup-compute.sh   distro-agnostic config (modprobe + udev + drop-in + initramfs)
udev/                start/stop nvidia-persistenced on PCI add/remove
systemd/             eGPU-aware drop-in (no boot failure when no GPU)
docs/                detailed install, procedure, troubleshooting, references
```

## Quick start

```bash
# 1. Install packages (per-distro details: docs/install.md)
#    Fedora:
sudo dnf config-manager addrepo --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora$(rpm -E %fedora)/x86_64/cuda-fedora$(rpm -E %fedora).repo
sudo dnf install -y nvidia-driver-cuda nvidia-persistenced cuda-toolkit
#    Ubuntu:    sudo apt install nvidia-driver-cuda nvidia-persistenced cuda-toolkit
#    Arch:      sudo pacman -S nvidia-open nvidia-utils nvidia-persistenced cuda

# 2. Apply the compute-only configuration (modprobe blacklists + udev + systemd drop-in)
git clone https://github.com/quazardous/amd-usb4-egpu-toolkit
cd amd-usb4-egpu-toolkit
./scripts/setup-compute.sh

# 3. Add the kernel arg (Fedora; other bootloaders in docs/install.md)
sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=0"

# 4. Reboot
sudo reboot
```

## How to plug

```bash
# 0. Pre-flight check (verifies everything is ready, no leftover bad state)
./scripts/egpu-preflight.sh
# → must say "READY TO PLUG" (or READY WITH WARNINGS reviewed)
# → if NOT READY: fix listed failures first
```

Then physically:

```
1. eGPU enclosure: POWER OFF
2. Plug USB4 cable into the laptop
3. Power on the enclosure
4. Wait ~10s for NVRM init + GSP bootstrap
```

Then verify:

```bash
./scripts/egpu-diag.sh
# → Verdict: OK-Gen4x4 (USB4) or OK-Gen3x4 (TB3)
# → Safe nvidia-smi: YES

nvidia-smi
# → your GPU listed, Persistence-M: On
```

If `egpu-diag.sh` reports **`BUG-Gen1-AMD-Phoenix`**, do NOT call `nvidia-smi` (cascade risk). Power‑cycle the enclosure and re‑plug — the bug is intermittent and usually clears on a second attempt.

Full procedure, full verification, benchmark reference numbers: [docs/procedure.md](docs/procedure.md).

## Troubleshoot

When something goes wrong, the diagnosis flow is:

```bash
./scripts/egpu-preflight.sh    # before plug — is the system in a usable state?
./scripts/egpu-diag.sh         # any time — what's the current link / driver state?
```

Common scenarios and how to fix them — full tree + glossary in [docs/troubleshooting.md](docs/troubleshooting.md):

| Symptom | First action |
|---|---|
| `nvidia-smi` hangs (no output) | **DON'T** run it again. Reboot. See the NVRM cascade explanation. |
| `nvidia-smi` says "No devices found" while the eGPU is plugged | Driver lost session. Check `nvidia-persistenced` is `active`. Reboot if needed. |
| Display freezes when eGPU is plugged | `nvidia-drm` is loaded. Re‑run `setup-compute.sh`, reboot. |
| Verdict reports `BUG-Gen1-AMD-Phoenix` | Phoenix x1‑Gen1 bug fired. Power‑cycle the enclosure and re‑plug. |
| `nvidia-persistenced` keeps failing at boot | Drop-in missing. Re‑run `setup-compute.sh`, reboot. |
| Preflight reports `nvidia-persistenced failed N time(s) since boot` | Stale journal traces from before the fix. Reboot to clear the count. |

To recover from a cascade (D-state `nvidia-smi`, system partially deadlocked):
```bash
sudo systemctl --force --force reboot
```
If that hangs too: switch to a TTY (`Ctrl+Alt+F3`), retry. Last resort: SysRq REISUB or 10s power button.

## Documentation

| | |
|---|---|
| [docs/why.md](docs/why.md) | Why this toolkit exists, why compute‑only, known limits |
| [docs/install.md](docs/install.md) | Detailed install per distro (Fedora, Ubuntu, Arch) + setup details |
| [docs/procedure.md](docs/procedure.md) | Connection procedure, verification, benchmark reference numbers |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Troubleshooting tree + glossary (Xid 79, GSP, RmInitAdapter, …) |
| [docs/references.md](docs/references.md) | NVIDIA docs, bug threads, community resources |

## Contributing

Issues and PRs welcome. Tested hardware combinations and distro install instructions especially appreciated.

## License

MIT — see [LICENSE](LICENSE).
