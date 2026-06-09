# References

Curated links that informed the diagnosis and design of this toolkit. Not exhaustive — see linked threads for follow‑on context.

## NVIDIA official documentation

- [Xid Errors — analyzing the catalog](https://docs.nvidia.com/deploy/xid-errors/analyzing-xid-catalog.html) — canonical reference for Xid 79 and other GPU error codes
- [Driver Persistence — overview](https://docs.nvidia.com/deploy/driver-persistence/index.html) — why `nvidia-persistenced` exists and what it solves
- [Driver Persistence — Persistence Daemon](https://docs.nvidia.com/deploy/driver-persistence/persistence-daemon.html) — daemon mode (recommended) vs legacy kernel persistence mode
- [GSP Firmware README (driver 580.x)](https://download.nvidia.com/XFree86/Linux-x86_64/580.119.02/README/kernel_open.html) — GSP requirements for the open kernel modules (Turing+)
- [open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) — source for the open NVIDIA kernel modules (CUDA 13 / driver 610 series)
- [nvidia-persistenced source](https://github.com/NVIDIA/nvidia-persistenced) — daemon source code + man page

## AMD Phoenix / Hawk Point / Strix USB4 eGPU bug

- [Framework Community — USB4 eGPU limited to PCIe Gen1 x1 on Framework 13 (Ryzen AI 300)](https://community.frame.work/t/usb4-egpu-limited-to-pcie-gen1-x1-on-framework-13-ryzen-ai-300-bios-03-05/79190) — most active thread tracking the bug, including BIOS attempts
- [Level1Techs — RX 9060 XT eGPU on Framework 13 (7840U) stuck at PCIe Gen1 x1, same dock works at Gen3 x4 on Intel](https://forum.level1techs.com/t/rx-9060-xt-egpu-on-framework-13-7840u-stuck-at-pcie-gen1-x1-same-dock-and-cables-run-gen3-x4-on-intel-pop-os-24-04-beta-on-both/239396) — clean side‑by‑side AMD vs Intel comparison, isolates the issue to the AMD host
- [egpu.io WIP — AMD Ryzen 9 6900HX (Rembrandt) + USB4 + RTX 3080](https://egpu.io/forums/thunderbolt-linux-setup/egpu-not-working-on-amd-ryzen-9-6900hx-rembrandt-usb4-wkgl17-c50-enclosure-rtx-3080/) — Rembrandt‑R reports (similar family, less severe)

## Xid 79 / driver session loss reports (Linux + NVIDIA forums)

- [NVIDIA Developer Forums — Xid 79 on idle (3090, Linux)](https://forums.developer.nvidia.com/t/xid-79-gpu-has-fallen-off-the-bus-happens-on-idle-only/323332) — pattern that `nvidia-persistenced` fixes
- [NVIDIA Developer Forums — Xid 79 after reboot, RTX 3090 not detected](https://forums.developer.nvidia.com/t/gpu-has-fallen-off-the-bus-xid-79-not-detected-after-reboot-rtx-3090/335612)
- [NVIDIA open-gpu-kernel-modules #900 — 5090 OCuLink PCIe4x4 Xid 79 under load](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/900) — same failure mode on a different external‑PCIe transport, confirms it's not USB4‑specific
- [Arch Linux Forum — Nvidia GPU has fallen off the bus](https://bbs.archlinux.org/viewtopic.php?id=304020) — community workarounds

## Tools used by `egpu-stress.sh`

- [gpu-burn (Ville Timonen)](https://github.com/wilicc/gpu-burn) — sustained CUBLAS GEMM load + optional VRAM corruption check
- [NVIDIA cuda-samples](https://github.com/NVIDIA/cuda-samples) — `deviceQuery` (still maintained); `bandwidthTest` was removed in 2025 and is replaced by the embedded `bw.cu` shipped here

## eGPU community resources

- [egpu.io](https://egpu.io) — community wiki, Linux setup guides, hardware compatibility reports
- [r/eGPU](https://www.reddit.com/r/eGPU/) — active subreddit; search for AMD + USB4 threads
- [bolt — Thunderbolt 3 / USB4 userspace daemon](https://gitlab.freedesktop.org/bolt/bolt) — the daemon behind `boltctl`, used here to enroll/authorize devices
