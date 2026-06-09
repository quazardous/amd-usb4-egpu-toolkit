# amd-usb4-egpu-toolkit

Toolkit for running an **NVIDIA eGPU as a CUDA-only compute accelerator** on a Linux laptop with an **AMD USB4** host (Phoenix / Hawk Point / Strix family) — Ollama, llama.cpp, ComfyUI, PyTorch, etc.

Not a gaming/display eGPU helper. The eGPU stays headless and the laptop's iGPU keeps driving the screen.

## Why this exists

The combo *AMD USB4 + NVIDIA eGPU + Linux* hits three pain points that other guides cover poorly:

1. **AMD Phoenix x1‑Gen1 PCIe tunnel bug** — the USB4 PCIe tunnel negotiates `2.5 GT/s × 1 lane` (≈ 0.25 GiB/s) instead of nominal Gen3/Gen4, intermittently. When it fires, the GPU GSP firmware bootstrap times out → **Xid 79 "GPU has fallen off the bus"** during driver init.
2. **NVRM cascade deadlock** — after Xid 79, the driver keeps the device bound but in a broken state. The next `nvidia-smi` takes a kernel spinlock waiting on the dead GPU → uninterruptible sleep (D state), unkillable even with SIGKILL. Subsequent `nvidia-smi` calls stack on the same lock. PCI remove and `modprobe -r` deadlock the same way. **Only a reboot recovers.**
3. **Silent driver session loss on idle** — without `nvidia-persistenced` keeping `/dev/nvidia0` open, the driver loses GSP session after idle. Next CUDA call fails with `RmInitAdapter failed (0x22:0x56:???)` / `osInitNvMapping: Cannot attach gpu` — no Xid logged, easy to miss, same lockup pattern as Xid 79.

This toolkit gives you:
- **A correct compute-only software stack** (modprobe blacklists + udev + systemd drop-in)
- **A safe passive diagnostic** that tells you whether `nvidia-smi` is safe to invoke (without invoking it)
- **A connection procedure** that maximizes the chance of a clean PCIe negotiation
- **Stress benchmarks** (deviceQuery, H↔D bandwidth, gpu-burn) that don't pull display libraries

## Hardware compatibility

Designed for and tested on:

| Component | Examples |
|---|---|
| Laptop SoC | AMD Ryzen 7xxx/8xxx series with USB4 (Phoenix, Hawk Point, Strix) |
| eGPU enclosure | Razer Core X V2 (USB4), Razer Core X (TB3), Aorus / Akitio / similar |
| eGPU GPU | NVIDIA RTX 30xx / 40xx (open driver), workstation A‑series |
| Distro | Any with systemd + udev. Fedora 44+, Ubuntu 24.04+, Arch documented. |
| Kernel | 6.6+ recommended (newer kernels handle USB4 retimer training better) |

Reports from other AMD USB4 laptops (Framework AMD, ASUS Zenbook AMD, etc.) welcome.

Should also be fine for Intel USB4 hosts — the persistence/cascade fixes are vendor-agnostic. The Phoenix x1‑Gen1 specifically is AMD‑side; if you're on Intel and never see `BUG‑Gen1‑AMD‑Phoenix` in the diagnostic, that's expected.

## What's in here

```
scripts/
  egpu-diag.sh        Passive diagnostic. Never touches the driver. Tells you
                      what state the system is in and whether nvidia-smi is
                      safe to invoke.
  egpu-stress.sh      Installs and runs deviceQuery + bandwidth bench + gpu-burn.
                      Builds everything in ~/.local/share/egpu-tools/, zero
                      system install, zero display lib pulled in.
  setup-compute.sh    Distro-agnostic config:
                        - /etc/modprobe.d/blacklist-nouveau.conf
                        - /etc/modprobe.d/nvidia-compute-only.conf
                        - /etc/udev/rules.d/99-nvidia-egpu-persistenced.rules
                        - /etc/systemd/system/nvidia-persistenced.service.d/override.conf
                        - regen initramfs (auto-detects dracut / update-initramfs / mkinitcpio)
                        - prints kernel cmdline instructions per bootloader
udev/
  99-nvidia-egpu-persistenced.rules    Start/stop nvidia-persistenced on PCI add/remove
systemd/
  nvidia-persistenced.service.d/
    override.conf     Make nvidia-persistenced eGPU-aware (no boot failure when no GPU)
```

## Install

### 1. Install distro packages

The proprietary NVIDIA driver itself is distro-specific. You need three packages:

- the kernel module + driver (`nvidia-driver-cuda` or equivalent, NOT the full display driver)
- `nvidia-persistenced` daemon
- the CUDA toolkit (for `nvcc`, optional but recommended)

**Fedora 44+** (NVIDIA CUDA repo — recommended for latest drivers):
```bash
sudo dnf config-manager addrepo --from-repofile=https://developer.download.nvidia.com/compute/cuda/repos/fedora$(rpm -E %fedora)/x86_64/cuda-fedora$(rpm -E %fedora).repo
sudo dnf install -y nvidia-driver-cuda nvidia-persistenced cuda-toolkit
```

**Ubuntu 24.04+**:
```bash
# NVIDIA CUDA repo setup → see https://developer.nvidia.com/cuda-downloads
sudo apt install nvidia-driver-cuda nvidia-persistenced cuda-toolkit
```

**Arch / Manjaro**:
```bash
sudo pacman -S nvidia-open nvidia-utils nvidia-persistenced cuda
```
(`nvidia-open` is the open kernel module variant, recommended for Turing+ / RTX 20xx+. Use `nvidia-dkms` for older cards.)

### 2. Apply the compute-only configuration

```bash
git clone https://github.com/quazardous/amd-usb4-egpu-toolkit
cd amd-usb4-egpu-toolkit
./scripts/setup-compute.sh
```

This is idempotent and asks before each sudo write.

### 3. Add the kernel command line argument

`setup-compute.sh` prints the right command for your bootloader at the end. For Fedora:
```bash
sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=0"
```

### 4. Reboot

```bash
sudo reboot
```

After reboot, you should have:
- nouveau blacklisted
- nvidia‑drm / nvidia‑modeset blacklisted (compute-only)
- udev rule in place
- nvidia-persistenced enabled but skipped at boot (waiting for the eGPU)

## The connection procedure

Once everything is installed, **the order of operations matters** for getting a clean PCIe negotiation:

```
1. Boot laptop, desktop fully loaded
2. eGPU enclosure: POWER OFF
3. Plug the USB4 cable into the laptop (vendor-supplied short cable preferred)
4. Power on the eGPU enclosure
5. Wait ~10 seconds (NVRM init + GSP bootstrap)
6. Verify with: ./scripts/egpu-diag.sh
   → Verdict should be OK-Gen4x4 (USB4) or OK-Gen3x4 (TB3)
   → Safe nvidia-smi: YES
7. nvidia-smi
```

If `egpu-diag.sh` reports `BUG-Gen1-AMD-Phoenix`, **don't** invoke nvidia-smi yet — the GSP bootstrap will time out and you'll be stuck. Power-cycle the eGPU and try again. The bug is intermittent: a second plug after a power cycle often re-trains the link to Gen4 cleanly.

## Verification & benchmarks

```bash
./scripts/egpu-stress.sh install      # builds tools in ~/.local/share/egpu-tools/

./scripts/egpu-stress.sh query        # deviceQuery — does CUDA see the GPU?
./scripts/egpu-stress.sh bandwidth    # measures real PCIe throughput
./scripts/egpu-stress.sh burn 60      # full-load 60s, tests link stability
./scripts/egpu-stress.sh burn-mem 60  # + VRAM corruption check
```

Reference numbers on **USB4 + RTX 3090 + AMD Phoenix**:

| Metric | Value | Note |
|---|---|---|
| PCIe link (sysfs) | Gen4 × 4 (16.0 GT/s × 4) | between TB router and GPU |
| H → D bandwidth | ~3.5 GiB/s | TB4 tunnel ceiling, not Phoenix bug |
| D → H bandwidth | ~3.5 GiB/s | idem |
| D → D bandwidth | ~390 GiB/s | RTX 3090 GDDR6X |
| gpu-burn sustained | ~27 TFLOPS FP32 | 76% of theoretical 35.6 TFLOPS |

The ~3.5 GiB/s H↔D is the **expected TB4/USB4 ceiling** (40 Gbit/s tunnel ≈ 4 GiB/s effective after protocol overhead). For workloads that fit the eGPU pattern (model loaded once into VRAM, minimal PCIe traffic during inference), this is plenty.

For DataLoader-heavy training, 3.5 GiB/s is about 8× slower than a workstation Gen4 ×16 (28 GiB/s) — workable for small batches, painful for large datasets.

## Troubleshooting tree

| Symptom | Verdict from `egpu-diag.sh` | Action |
|---|---|---|
| `nvidia-smi` shows the GPU | `OK-Gen4x4`, `Safe = YES` | All good. Work. |
| `nvidia-smi` says "No devices found" | `OK-…`, `RmInit fail (5min) ≥ 1` | Driver lost session. Reboot or replug. Make sure `nvidia-persistenced` is `active`. |
| `nvidia-smi` hangs (no output) | `RmInit fail ≥ 1` OR `Stuck D ≥ 1` | Don't run nvidia-smi again. Reboot. See [Xid 79 cascade](#glossary). |
| Link reports Gen1 × 1 | `BUG-Gen1-AMD-Phoenix` | Power-cycle eGPU. Try the other USB4 port if available. |
| Display freezes when eGPU plugged | (check `lsmod | grep nvidia-drm`) | nvidia-drm is loaded. Re-run `setup-compute.sh` and reboot — the blacklist must be in place. |
| `nvidia-persistenced` keeps failing | `persistenced: inactive` | The udev rule should auto-start it on plug. If it doesn't, check `journalctl -u nvidia-persistenced` and `udevadm monitor` while plugging. |
| Whole system freezes when unplugging eGPU | (cascade) | Held NVRM spinlock. Hard reset. If it happens repeatedly, you may have nouveau loading — ensure blacklist + initramfs regen. |

## Glossary

**Xid 79 — "GPU has fallen off the bus"**
NVIDIA driver detected that the GPU stopped responding to PCIe register reads. On eGPU, this typically means the PCIe link/tunnel had a hiccup (Phoenix x1‑Gen1 bug, retimer training failure, marginal cable, etc.) and the GSP firmware bootstrap timed out. After Xid 79 the driver does not recover gracefully — it holds a kernel spinlock that any subsequent CUDA call will try to acquire, deadlocking the calling process in uninterruptible sleep.

**RmInitAdapter failed**
The driver's adapter init routine bailed. Distinct from Xid 79 (which fires on a hardware unresponsive event) — this is a softer failure mode where the driver lost its session (often after idle without `nvidia-persistenced`) and can't reattach. Same lockup pattern on subsequent CUDA calls. `osInitNvMapping: Cannot attach gpu` accompanies it.

**Phoenix x1‑Gen1 bug**
On AMD Family 19h Phoenix and derivatives, the USB4 PCIe tunnel sometimes negotiates `2.5 GT/s × 1 lane` instead of the full Gen3/Gen4 x4 the link supports. At 0.25 GiB/s, anything requiring sustained PCIe traffic times out, including the GSP RPC bootstrap. The bug is **intermittent** — re-plugging often gives a clean negotiation. Root cause is hardware/firmware AMD-side, no kernel fix available.

**GSP firmware**
Since driver 535+, NVIDIA forces a small RISC-V firmware (GSP) on Turing and later GPUs that handles much of what used to be host-driver work. It requires reliable, fast PCIe communication during bootstrap. This is what fails first when the PCIe link is marginal.

**`nvidia-persistenced`**
Userspace daemon that keeps `/dev/nvidia0` open continuously, preventing the driver from going through the open→init→close→reinit cycle between CUDA app invocations. On eGPU this is mandatory — without it, the driver loses GSP session after idle and the next CUDA call lockups.

**Compute-only mode**
The eGPU loads `nvidia.ko` + `nvidia-uvm.ko` (sufficient for CUDA) but NOT `nvidia-drm.ko` or `nvidia-modeset.ko`. No `/dev/dri/cardN` is created for the eGPU, so GNOME/mutter doesn't try to enumerate it as a render device. This sidesteps a class of mutter freeze bugs on hot-plug.

## Known limitations

- **No display support.** By design — see [Why compute-only](#why-compute-only). If you want to drive a monitor from the eGPU, this toolkit isn't for you (yet).
- **NVIDIA only.** Not tested with AMD eGPUs. The persistence/compute-only patterns don't apply the same way.
- **Single eGPU.** The udev rule starts a single `nvidia-persistenced` regardless of GPU count. Should work for multi-GPU eGPU racks but untested.

## Why compute-only

Trying to plug a display into the eGPU on Linux with hot-plug brings a separate stack of problems:
- mutter PRIME render-offload enumeration freezes the compositor on slow eGPU buses
- EDID propagation through the USB4 tunnel is unreliable
- suspend/resume with a display attached on eGPU has its own bugs
- driver mode (modeset=0 vs 1) interacts with the X session manager

For pure compute (Ollama, ComfyUI, llama.cpp, PyTorch), none of these matter — the eGPU is just a CUDA accelerator that doesn't need to be a display device. Drastically smaller surface, way more reliable.

A future scope of this toolkit may cover the display path with workarounds. PRs welcome.

## Contributing

Issues and PRs welcome. Useful contributions:
- Tested hardware combinations (laptop SoC + eGPU enclosure + GPU model)
- Distro install instructions (BSD, NixOS, openSUSE, etc.)
- Other failure modes + diag verdicts to add

## License

MIT — see [LICENSE](LICENSE).
