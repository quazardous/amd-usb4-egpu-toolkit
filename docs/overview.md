# Overview

Everything that is not the problem statement or the quick start.
Back to the [README](../README.md).

**Validated on:** Lenovo ThinkPad P14s Gen 5 AMD (Ryzen 7 PRO 8840HS, Hawk Point) + Razer Core X V2 (USB4) + NVIDIA RTX 3090 — Fedora 44, kernel 7.2.9, closed driver 615.71.09 with GSP off (2026-10-09): link held PCIe Gen4 x4 through a 120 s `gpu-burn`, 3.57 GiB/s host↔device.

## Hardware compatibility

| Component | Examples |
|---|---|
| Laptop SoC | AMD Ryzen 7xxx/8xxx series with USB4 (Phoenix, Hawk Point, Strix) |
| eGPU enclosure | Razer Core X V2 (USB4), Razer Core X (TB3), Aorus / Akitio / similar |
| eGPU GPU | NVIDIA RTX 30xx / 40xx, workstation A‑series (**closed** driver if you use `gsp-off.sh`) |
| Distro | Any with systemd + udev (Fedora 44+, Ubuntu 24.04+, Arch) |
| Kernel | 6.6+ recommended |

Should also work on Intel USB4 hosts — the persistence/cascade fixes are vendor‑agnostic. The Phoenix x1‑Gen1 specifically is AMD‑side.

## What's in here

```
install.sh            one-shot Fedora install (driver, closed module, config, GSP off)
scripts/
  egpu-preflight.sh   pre-plug readiness check (config in place, no leftover bad state)
  egpu-diag.sh        passive live diagnostic, never touches the driver
  egpu-eject.sh       detach the eGPU cleanly before unplugging (--undo to cancel)
  egpu-recover.sh     guided recovery from a stuck driver (cascade, WPR2, etc.)
  egpu-postmortem.sh  retrospective analysis: per-boot summary + detail mode
  egpu-stress.sh      deviceQuery + bandwidth + gpu-burn, compute-only safe
  setup-compute.sh    distro-agnostic config (modprobe + udev + drop-in + initramfs)
  shutdown-helper.sh  shutdown-time eGPU teardown (installed in /usr/local/lib)
  gsp-off.sh          opt-in workaround: disable NVIDIA GSP firmware (closed driver only)
gnome-extension/      eGPU Indicator: panel status + eject (GNOME 50)
udev/                 start/stop nvidia-persistenced on driver bind/unbind, log GPU link state
systemd/              eGPU-aware drop-in + shutdown hook
docs/                 detailed install, procedure, troubleshooting, references
```

## Manual install

`install.sh` automates Fedora. For other distros, or to run the steps by hand,
see [install.md](install.md), then apply the compute-only configuration with
`scripts/setup-compute.sh`, add `nvidia-drm.modeset=0` to the kernel command
line and reboot.

## Troubleshoot

When something goes wrong, the diagnosis flow is:

```bash
./scripts/egpu-preflight.sh    # before plug — is the system in a usable state?
./scripts/egpu-diag.sh         # any time — what's the current link / driver state?
./scripts/egpu-postmortem.sh   # after the fact — what happened across recent boots?
```

Common scenarios and how to fix them — full tree + glossary in [troubleshooting.md](troubleshooting.md):

| Symptom | First action |
|---|---|
| `nvidia-smi` hangs (no output) | **DON'T** run it again. Reboot. See the NVRM cascade explanation. |
| `nvidia-smi` says "No devices found" while the eGPU is plugged | Driver lost session. Check `nvidia-persistenced` is `active`. Reboot if needed. |
| Display freezes when eGPU is plugged | `nvidia-drm` is loaded. Re‑run `setup-compute.sh`, reboot. |
| Verdict reports `BUG-Gen1x1-AMD-Phoenix` | Phoenix x1‑Gen1 bug fired. Power‑cycle the enclosure and re‑plug. |
| `nvidia-persistenced` keeps failing at boot | Drop-in missing. Re‑run `setup-compute.sh`, reboot. |
| `nvidia-persistenced` stays `inactive` after plugging | Old udev rule (fired on PCI add, before the driver binds). Re‑run `setup-compute.sh`. |
| Kernel prints `limited by 2.5 GT/s PCIe x1 link at 0000:00:0x.1` | **Not** the Phoenix bug: the AMD USB4 tunnel port is virtual and always reports Gen1 x1. Trust `egpu-diag.sh` (the GPU's own link). |
| `nouveau ... gsp: init failed, -110` | nouveau's GSP bootstrap timed out. Use the closed NVIDIA driver + `gsp-off.sh` (nouveau cannot run Ampere+ without GSP). |
| Closed module expected but `modinfo -F license nvidia` says `Dual MIT/GPL` | RPM Fusion built the open module. See the Fedora section of docs/install.md. |
| Preflight reports `nvidia-persistenced failed N time(s) since boot` | Stale journal traces from before the fix. Reboot to clear the count. |
| Shutdown / poweroff hangs at the Fedora spinner | `nvidia-egpu-shutdown.service` missing or disabled. Re‑run `setup-compute.sh` (it installs + enables the hook that cleanly unloads nvidia.ko before TB teardown). |

To recover from a cascade (D-state `nvidia-smi`, system partially deadlocked):
```bash
sudo systemctl --force --force reboot
```
If that hangs too: switch to a TTY (`Ctrl+Alt+F3`), retry. Last resort: SysRq REISUB or 10s power button.

## Documentation

| | |
|---|---|
| [docs/why.md](why.md) | Why this toolkit exists, why compute‑only, known limits |
| [docs/install.md](install.md) | Detailed install per distro (Fedora, Ubuntu, Arch) + setup details |
| [docs/procedure.md](procedure.md) | Connection procedure, verification, benchmark reference numbers |
| [docs/troubleshooting.md](troubleshooting.md) | Troubleshooting tree + glossary (Xid 79, GSP, RmInitAdapter, …) |
| [docs/references.md](references.md) | NVIDIA docs, bug threads, community resources |

