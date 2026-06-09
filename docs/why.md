# Why this toolkit exists

The combo *AMD USB4 + NVIDIA eGPU + Linux* hits three pain points that other guides cover poorly. Each is non‑obvious, none are well‑documented in vendor docs, and they compound.

## 1. AMD Phoenix x1‑Gen1 PCIe tunnel bug

On AMD Family 19h Phoenix and derivatives (Phoenix, Hawk Point, Strix), the USB4 PCIe tunnel sometimes negotiates `2.5 GT/s × 1 lane` (≈ 0.25 GiB/s) instead of nominal Gen3 or Gen4 ×4 (3–8 GiB/s). The bug is **intermittent** — a re‑plug after a power cycle often gives a clean Gen3/Gen4 ×4 negotiation.

When it fires: the GPU GSP firmware bootstrap RPC times out (it expects fast register reads/writes during init) → **Xid 79 "GPU has fallen off the bus"** during driver init, before any CUDA call.

Root cause is hardware/firmware AMD‑side. No kernel fix available as of mid‑2026. Multiple BIOS attempts on Framework laptops haven't resolved it. See [references](references.md) for community tracking.

## 2. NVRM cascade deadlock after Xid 79

After Xid 79, the driver keeps the device bound but in a broken internal state. The next `nvidia-smi` (or any CUDA app) does this:

```
nvidia_open_deferred → nv_open_device → nv_start_device → RmInitAdapter
                                                          → kgspBootstrap_TU102
                                                          → kgspWaitForRmInitDone_IMPL
                                                          → _kgspRpcRecvPoll    ← spinlocks forever
```

The process acquires a kernel spinlock and waits on an RPC poll from a dead GSP → **uninterruptible sleep (D state)**, unkillable even with SIGKILL. Subsequent `nvidia-smi` calls stack on the same lock. `echo 1 > /sys/.../remove` also deadlocks (PCI remove tries the same locks). Physical unplug fires `pciehp` surprise‑remove which calls the same `.remove()` callback → same deadlock.

**Only a hard reboot recovers.** No workaround in user‑space.

## 3. Silent driver session loss on idle

Without `nvidia-persistenced` keeping `/dev/nvidia0` open, the driver tears down the device state when no CUDA client is connected (this is the default behavior, by design for permanent‑GPU setups).

On eGPU, this open→init→close→reinit cycle fails on the *reinit* part. Symptom: after some idle time, the next CUDA call fails with:

```
NVRM: osInitNvMapping: *** Cannot attach gpu
NVRM: RmInitAdapter failed! (0x22:0x56:???)
```

No Xid is logged — easy to miss. Same lockup pattern as Xid 79 on subsequent calls. `nvidia-persistenced` fixes this entirely by keeping the device perpetually "attached" between CUDA app invocations.

## Why compute-only

Trying to plug a display into the eGPU on Linux with hot‑plug brings a *separate* stack of problems that this toolkit deliberately avoids:

- **GNOME/mutter PRIME render-offload enumeration** freezes the compositor when it tries to use a slow eGPU as a render device
- **EDID propagation through the USB4 tunnel** is unreliable
- **Suspend/resume with a display on eGPU** has its own bugs
- **Driver mode (`nvidia-drm.modeset=0` vs `1`)** interacts with the X session manager and display server choice

For pure compute (Ollama, ComfyUI, llama.cpp, PyTorch), none of these matter — the eGPU is just a CUDA accelerator, no display device. Drastically smaller bug surface, way more reliable.

In compute-only mode the toolkit:
- loads `nvidia.ko` + `nvidia-uvm.ko` (sufficient for CUDA)
- blacklists `nvidia-drm.ko` and `nvidia-modeset.ko`
- adds `nvidia-drm.modeset=0` as defense-in-depth kernel arg
- consequence: no `/dev/dri/cardN` for the eGPU → GNOME never tries to enumerate it as a render device

A future scope may cover the display path with workarounds. PRs welcome.

## Known limitations

- **No display support.** By design — see above. Want to drive a monitor from the eGPU? This toolkit isn't for you (yet).
- **NVIDIA only.** Not tested with AMD eGPUs. The persistence/compute-only patterns don't apply the same way.
- **Single eGPU.** The udev rule starts a single `nvidia-persistenced` regardless of GPU count. Should work for multi‑GPU eGPU racks but untested.
- **No automatic recovery from Xid 79.** If you hit the cascade, only a reboot recovers — same as everyone else dealing with this driver bug.
