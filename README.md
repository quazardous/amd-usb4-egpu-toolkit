# amd-usb4-egpu-toolkit

NVIDIA eGPU as a **CUDA‑only compute accelerator** on a Linux laptop with an
**AMD USB4** host (Ryzen Phoenix / Hawk Point / Strix) — Ollama, llama.cpp,
ComfyUI, PyTorch. The eGPU stays headless; the laptop's iGPU keeps driving the
screen.

## The problem

Plug an NVIDIA eGPU into an AMD USB4 laptop on Linux and it often fails:

- the driver's start-up times out over the USB4 tunnel (GSP firmware), giving
  `Xid 79 "GPU has fallen off the bus"`, or nouveau's `gsp: init failed, -110`;
- once that happens, `nvidia-smi` hangs and only a reboot recovers (NVRM cascade);
- left idle, the driver loses the GPU and the next CUDA call hangs;
- GNOME freezes as soon as it tries to use the eGPU as a display.

The fix: **closed NVIDIA driver with the GSP firmware turned off**, **compute
only** (no `nvidia-drm`), and **`nvidia-persistenced` started on plug**.
Validated on a ThinkPad P14s Gen 5 AMD + Razer Core X V2 + RTX 3090: PCIe Gen4
x4 held through sustained load, 3.57 GiB/s host↔GPU.
Details: [docs/why.md](docs/why.md).

## Quick start (Fedora)

eGPU **unplugged**, then:

```bash
git clone https://github.com/quazardous/amd-usb4-egpu-toolkit && ./amd-usb4-egpu-toolkit/install.sh
```

Reboot. Then, from `amd-usb4-egpu-toolkit/`: `./scripts/egpu-preflight.sh` (must say READY TO PLUG),
enclosure **off** → cable in → enclosure **on**, and check with
`./scripts/egpu-diag.sh` (verdict `OK-Gen4x4`) before `nvidia-smi`.

Add `--with-cuda-toolkit` for `nvcc` and the stress tests. Other distros:
[docs/install.md](docs/install.md).

## More

[Overview, hardware, troubleshooting](docs/overview.md) ·
[Install details](docs/install.md) ·
[Plug / verify / benchmarks](docs/procedure.md) ·
[Troubleshooting](docs/troubleshooting.md) ·
[Sources](docs/references.md) ·
[Wiki](https://github.com/quazardous/amd-usb4-egpu-toolkit/wiki)

## Contributing

Issues and PRs welcome. Tested hardware combinations and distro install instructions especially appreciated.

## License

MIT — see [LICENSE](LICENSE).
