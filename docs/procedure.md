# Connection procedure & benchmarks

## The procedure

Once everything from [install.md](install.md) is in place, **the order of operations matters** for getting a clean PCIe negotiation:

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

If `egpu-diag.sh` reports `BUG-Gen1-AMD-Phoenix`, **don't** invoke `nvidia-smi` yet — the GSP bootstrap will time out and you'll be stuck in the [NVRM cascade](troubleshooting.md#nvrm-cascade-deadlock-after-xid-79). Power‑cycle the eGPU and try again. The bug is intermittent: a second plug after a power cycle often re‑trains the link to Gen4 cleanly.

## What the udev rule does for you

The toolkit installs a udev rule that calls `systemctl start nvidia-persistenced.service` automatically when an NVIDIA display device appears on the PCI bus (and `stop` when it disappears). Combined with the `ConditionPathExists=/dev/nvidia0` drop‑in, this means:

- Boot without the eGPU: `nvidia-persistenced` skips cleanly, no failure
- Plug the eGPU: udev fires the rule → service starts → device stays warm
- Unplug: udev fires the remove rule → service stops cleanly
- Re‑plug: starts again, no `systemctl reset-failed` needed

## Verification

Quick sanity check:

```bash
./scripts/egpu-diag.sh
# Expect:
#   Verdict: OK-Gen4x4 (USB4) or OK-Gen3x4 (TB3)
#   nvidia-persistenced: active
#   Safe nvidia-smi: YES

nvidia-smi
# Expect Persistence-M: On
```

Build the benchmark tools (one‑time, ~5 min):

```bash
./scripts/egpu-stress.sh install
```

Run them in order:

```bash
./scripts/egpu-stress.sh query        # deviceQuery: SM count, VRAM, capabilities
./scripts/egpu-stress.sh bandwidth    # H↔D / D↔H / D↔D throughput
./scripts/egpu-stress.sh burn 60      # 60s sustained full-load (CUBLAS GEMM)
./scripts/egpu-stress.sh burn-mem 60  # + VRAM corruption check
```

While `burn` runs, you can keep `./scripts/egpu-diag.sh --watch` in another terminal to monitor the link state live.

## Reference numbers

Validated on **Lenovo ThinkPad T14s Gen 5 AMD** (Ryzen 7 PRO 8840HS, Hawk Point) + Razer Core X V2 (USB4) + NVIDIA RTX 3090:

| Metric | Value | Note |
|---|---|---|
| PCIe link (sysfs) | Gen4 × 4 (16.0 GT/s × 4) | between TB router and GPU |
| H → D bandwidth | ~3.5 GiB/s | TB4 tunnel ceiling, not Phoenix bug |
| D → H bandwidth | ~3.5 GiB/s | idem |
| D → D bandwidth | ~390 GiB/s | RTX 3090 GDDR6X |
| `gpu-burn` sustained | ~27 TFLOPS FP32 | 76% of theoretical 35.6 TFLOPS |

### Why H↔D tops at ~3.5 GiB/s

That's the **expected TB4/USB4 ceiling** — 40 Gbit/s tunnel ≈ 4 GiB/s effective after protocol framing overhead. It's NOT the Phoenix bug (which would give ≈0.25 GiB/s).

Comparison points:
- Bug Phoenix x1‑Gen1: ~0.25 GiB/s
- TB3 effective ceiling: ~2.5 GiB/s
- **TB4/USB4 effective ceiling: ~4 GiB/s** ← what you should see
- PCIe Gen4 x16 direct (desktop GPU): ~28 GiB/s

### Workload impact

For workloads that fit the eGPU pattern, the ~3.5 GiB/s bottleneck is fine:

- **Ollama, llama.cpp** — model loaded once into VRAM, then minimal PCIe traffic. Near‑zero impact at inference time.
- **ComfyUI, SDXL, Flux** — slight delay loading the model from disk → VRAM. Generation itself is insensitive.
- **PyTorch training with a large DataLoader** — each batch streams over PCIe. 8× slower than a desktop Gen4 ×16 path. Workable for small batches, painful for large datasets.
