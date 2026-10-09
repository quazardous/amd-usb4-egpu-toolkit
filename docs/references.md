# References

Sources that informed the diagnosis and design of this toolkit. Not exhaustive — see linked threads for follow‑on context.

Entries marked *(checked locally)* were verified on the reference machine
(ThinkPad P14s Gen 5 AMD + Razer Core X V2 + RTX 3090, Fedora 44) on
2026‑10‑09 rather than taken from the linked page alone.

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

## Closed driver and GSP off

- [NVIDIA Driver Installation Guide, Release 615](https://docs.nvidia.com/datacenter/tesla/pdf/Driver_Installation_Guide.pdf) — §4.1 "Proprietary Kernel Modules Removed": *"The proprietary kernel modules have been removed. The open kernel modules are now the only kernel module flavor provided."* Why the driver can no longer come from NVIDIA's CUDA repository when the GSP must be turned off.
- [open-gpu-kernel-modules discussion #667](https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/667) and [#899](https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/899) — the open modules always boot the GSP; `NVreg_EnableGpuFirmware=0` has no effect there.
- [ArchWiki — NVIDIA](https://wiki.archlinux.org/title/NVIDIA) — GSP firmware failures on Ampere laptops; workaround: proprietary module + `NVreg_EnableGpuFirmware=0`.
- [GSP Firmware README (driver 570.x)](https://download.nvidia.com/XFree86/Linux-x86_64/570.169/README/gsp.html) — what the GSP does and its requirements.
- `NVreg_EnableGpuFirmware=0` honoured by the closed 615.71.09 module: `/proc/driver/nvidia/params` shows `EnableGpuFirmware: 0`, `nvidia-smi -q` shows `GSP Firmware Version: N/A` *(checked locally)*. The closed module does not expose the option under `/sys/module/nvidia/parameters/` *(checked locally)*.

## Same enclosure, same GPU

- [hvico/Razer-Core-v2-Linux-Fix](https://github.com/hvico/Razer-Core-v2-Linux-Fix) — Razer Core X V2 + RTX 3090 on an AMD USB4 host (ROG Flow Z13, Ryzen AI Max+ 395), Ubuntu 24.04, kernel 6.18, proprietary driver 590: GSP off, `thunderbolt.clx=0`, `thunderbolt.host_reset=0`, `pci=realloc`, PCI rescan before loading the driver, hot-plug after boot. (This toolkit's preflight found `thunderbolt.clx=0` ineffective.)
- [NVIDIA Developer Forums — GSP firmware from an AMD Strix laptop to a TB5 3090 eGPU causes instant reboot](https://forums.developer.nvidia.com/t/loading-gsp-firmware-from-an-amd-strix-laptop-to-a-tb5-3090-egpu-causes-instant-reboot/360903) — mostly stable with the proprietary module + GSP off, still unstable with the open module.
- [NVIDIA Developer Forums — driver malfunction on TUXEDO InfinityBook Pro 14 Gen 9 AMD, several distros](https://forums.developer.nvidia.com/t/nvidia-drivers-malfunction-on-tuxedo-infinitybook-pro14-gen9-amd-several-distros-versions/322313) — RTX 3090 on an AMD laptop, nouveau in control, NVIDIA driver failing across Ubuntu versions and Debian.
- [g0004y/razer-core-x-v2-nvidia-30-40-50-egpu-fix-linux](https://github.com/g0004y/razer-core-x-v2-nvidia-30-40-50-egpu-fix-linux) — RTX 40-series in the same enclosure, ThinkPad T14 Gen 3, Linux Mint.
- [Razer Core X V2 product page](https://www.razer.com/gaming-egpus/razer-core-x-v2) — officially Windows 10 RS5 / 11 only; 40 Gb/s over TB4/USB4.

## RPM Fusion packaging (Fedora)

- `nvidia-kmod` spec and its `nvidia-kmod-noopen-checks` script *(checked locally, from `/usr/src/akmods/nvidia-kmod-615.71.09-3.fc44.src.rpm`)* — the flavour is chosen at build time: open unless a GPU from `nvidia-kmod-noopen-pciids.txt` is present; `%_with_kmod_nvidia_open` forces open, `%_without_kmod_nvidia_detect` skips the detection and keeps the closed `kernel/` tree.
- `xorg-x11-drv-nvidia-kmodsrc` 595.58.03 and 615.71.09 both ship `kernel/` (`MODULE_LICENSE("NVIDIA")`) next to `kernel-open/` (`Dual MIT/GPL`) *(checked locally)*.
- akmods can print `Successful` while dnf answered *"available but not installed"*; a rebuilt kmod keeps the same NEVRA *(checked locally, `/var/cache/akmods/nvidia/*.log`)*.

## The "limited by 2.5 GT/s PCIe x1" kernel line

- [Framework Community — USB4 eGPU limited to PCIe Gen1 x1](https://community.frame.work/t/usb4-egpu-limited-to-pcie-gen1-x1-on-framework-13-ryzen-ai-300-bios-03-05/79190) — replies point out that USB4/Thunderbolt links are misreported by `lspci` and recommend benchmarking.
- On the AMD host, the USB4 tunnel ports report a fixed 2.5 GT/s x1 capability on both ports, while 3.57 GiB/s was measured host→GPU through them *(checked locally)*.

## Laptop

- [Lenovo PSREF — ThinkPad P14s Gen 5 AMD](https://psref.lenovo.com/syspool/Sys/PDF/ThinkPad/ThinkPad_P14s_Gen_5_AMD/ThinkPad_P14s_Gen_5_AMD_Spec.PDF) — specifications.
- [ArchWiki — Lenovo ThinkPad P14s (AMD) Gen 5](https://wiki.archlinux.org/title/Lenovo_ThinkPad_P14s_(AMD)_Gen_5) — hardware support status.
- [egpu.io — P14s Gen 4 AMD + RTX 4070 over USB4, Pop!_OS and Windows 11](https://egpu.io/forums/builds/2023-14-thinkpad-p14s-gen4amd-r7-7840u-radeon-780m-rtx-4070-64gbps-usb4v1adt-link-ut3g-linux-pop-os-22-04-win11/) — closest published build on the previous generation.
- BIOS settings readable from Linux through `think_lmi` (`/sys/class/firmware-attributes/thinklmi/attributes/`): the P14s Gen 5 AMD exposes 95 settings and none for Thunderbolt / USB4 / PCIe tunneling / Kernel DMA Protection *(checked locally, BIOS R2LET41W 1.22)*.

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
