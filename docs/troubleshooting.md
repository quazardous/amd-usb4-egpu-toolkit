# Troubleshooting & glossary

## Troubleshooting tree

Map your symptom to the right action. `Verdict` column refers to `./scripts/egpu-diag.sh` output.

| Symptom | Verdict | Action |
|---|---|---|
| `nvidia-smi` shows the GPU | `OK-Gen4x4`, `Safe = YES` | All good. Work. |
| `nvidia-smi` says "No devices found" | `OK-…`, `RmInit fail ≥ 1` | Driver lost session. Reboot or replug. Make sure `nvidia-persistenced` is `active`. |
| `nvidia-smi` hangs (no output) | `RmInit fail ≥ 1` OR `Stuck D ≥ 1` | Don't run `nvidia-smi` again. Reboot. See [NVRM cascade](#nvrm-cascade-deadlock-after-xid-79). |
| Link reports Gen1 ×1 | `BUG-Gen1-AMD-Phoenix` | Power‑cycle the eGPU enclosure. Try the other USB4 port if available. Re‑plug after a power cycle often gives a clean Gen4 ×4. |
| Display freezes when eGPU plugged | (check `lsmod \| grep nvidia-drm`) | `nvidia-drm` is loaded. Re‑run `setup-compute.sh` and reboot — the blacklist must be in place. |
| `nvidia-persistenced` keeps failing | `persistenced: inactive` | The udev rule should auto‑start it on plug. If it doesn't, check `journalctl -u nvidia-persistenced` and `udevadm monitor` while plugging. |
| Whole system freezes when unplugging eGPU | (cascade) | Held NVRM spinlock. Hard reset. If it happens repeatedly, you may have nouveau loading — ensure blacklist + initramfs regen. |
| `udev` rule not firing on plug | (check `udevadm test`) | See [Testing the udev rule](#testing-the-udev-rule) below. |
| Shutdown / poweroff hangs at the spinner | (n/a — happens post‑boot) | The `nvidia-egpu-shutdown.service` hook isn't installed or enabled. See [Shutdown hangs](#shutdown-hangs-at-poweroff) below. |

## Testing the udev rule

Without unplugging the eGPU, you can verify the rule matches your GPU and triggers the right command:

```bash
GPU_SYSFS=$(grep -l '^0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null | xargs -I{} dirname {} | head -1)
sudo udevadm test "$GPU_SYSFS" 2>&1 | grep -E 'RUN|PCI_CLASS|PCI_ID'
```

Expected output:
```
PCI_CLASS=30000
PCI_ID=10DE:2204
RUN{program} : /usr/bin/systemctl --no-block start nvidia-persistenced.service
```

Then test the live cycle:
```bash
sudo systemctl stop nvidia-persistenced.service
systemctl is-active nvidia-persistenced.service          # inactive
sudo udevadm trigger --action=add "$GPU_SYSFS"
sleep 2
systemctl is-active nvidia-persistenced.service          # active
```

## Last-resort: disable GSP firmware (opt-in workaround)

If the GSP-related cascades (Xid 79 from GSP bootstrap, `WPR2 already up`, `kgspWaitForRmInitDone` spinlock) are unbearable on your hardware, you can opt into disabling NVIDIA's on-GPU firmware bootstrap entirely:

```bash
./scripts/gsp-off.sh status       # current state
./scripts/gsp-off.sh enable       # writes /etc/modprobe.d/nvidia-gsp-off.conf
./scripts/gsp-off.sh disable      # remove and revert
# reboot for the change to take effect
```

**Important caveats:**

1. **Closed driver required.** The open kernel module (`kmod-nvidia-open-dkms`) ignores `NVreg_EnableGpuFirmware=0` — GSP is mandatory there. You need the proprietary module (`kmod-nvidia-dkms` on Fedora; `nvidia-dkms` on Arch; specific package names per distro). The script warns if your current driver flavor is `open` so you know to swap first.
2. **Deprecated by NVIDIA.** Works in driver 610 series, will be removed in a future release. Tactical workaround, not a long-term fix.
3. **Marginal perf hit** on sustained compute (clock/power management moves to the CPU side). Negligible for Ollama / inference; visible for heavy training.
4. **Doesn't fix the AMD Phoenix x1‑Gen1 PCIe bug** itself — GSP-off bypasses the GSP RPC timeout symptom but very large data transfers during driver init can still time out on an x1-Gen1 link.

Use when the cascade pattern becomes frequent enough that the productivity loss outweighs the perf cost.

## Shutdown hangs at poweroff

Symptom: `sudo poweroff` (or shutdown via the GUI) gets stuck on the Fedora/distro spinner. Eventually the watchdog reboots the laptop, or the user holds the power button.

Root cause: when `nvidia-persistenced` is stopped during shutdown, nvidia.ko's refcount drops, but the module may still hold references via subsystems that haven't been torn down yet. systemd then unloads modules in some order; if the TB stack starts removing the GPU's PCI device while nvidia hasn't finished its `.remove()` callback, the same NVRM lockup pattern as during a hot‑unplug fires — but in the middle of shutdown, where there's nowhere to go and no user input to react.

Fix: the toolkit installs a `nvidia-egpu-shutdown.service` shutdown hook that:

1. Stops `nvidia-persistenced` cleanly (releases `/dev/nvidia0`)
2. Unloads `nvidia_uvm` (with a 5s timeout)
3. Unloads `nvidia` itself (with a 10s timeout)

All this happens *before* `shutdown.target` is reached, so the TB stack tears down cleanly after the driver is already gone. If any step times out (because the driver is already in a stuck state), the hook gives up and lets systemd proceed — the goal is to make the *common* case smooth, not magically rescue a broken state.

To verify the hook is enabled:
```bash
systemctl is-enabled nvidia-egpu-shutdown.service   # → enabled
```

To see its logs after a shutdown:
```bash
journalctl -u nvidia-egpu-shutdown.service -b -1    # previous boot
journalctl -t nvidia-egpu-shutdown -b -1            # the helper's syslog messages
```

If it's missing, re‑run `setup-compute.sh` — it installs the service file, the helper script, and enables the unit.

## Forensic analysis of past sessions

To understand what happened across recent boots — useful when you've noticed flakiness over time but can't pin it on a single event:

```bash
./scripts/egpu-postmortem.sh                # summary table, last 10 boots
./scripts/egpu-postmortem.sh --last 30      # last 30 boots
./scripts/egpu-postmortem.sh --boot -3      # all relevant events from boot -3
./scripts/egpu-postmortem.sh --since "1 week ago"
./scripts/egpu-postmortem.sh --csv          # for piping into a spreadsheet
```

Per-boot counters:
- **Plug / Unpl** — eGPU PCI enable / pciehp link-down events
- **Xid** — NVRM Xid events (typically Xid 79 on eGPU)
- **RmInit** — `RmInitAdapter failed` / `Cannot attach gpu` silent failures
- **Phx** — number of times the link negotiated to `2.5 GT/s × 1` (Phoenix bug fired)
- **ShutOK** — `shutdown-helper.sh done` was logged at the end of that boot
- **Unmnt** — `Failed unmounting` / `A stop job is running` (shutdown trouble)
- **PersFl** — `nvidia-persistenced` failure events (rate-limit, query failures)

Rows colored:
- **green** — clean session
- **yellow** — Phoenix bug fired, or persistenced failed, or very short boot (possible cascade-and-reboot)
- **red** — Xid / RmInit / unmount failure → driver or shutdown issue

The detail mode (`--boot N`) groups the events into Thunderbolt/eGPU enumeration, NVIDIA driver lifecycle, persistenced, shutdown helper, shutdown failures, and other notable kernel events — useful when reconstructing exactly what happened that day.

## Recovering from the cascade without reboot

You can't, reliably. Once `nvidia-smi` is in D state (uninterruptible kernel sleep waiting on the GSP RPC), the only way out is a reboot:

```bash
sudo systemctl --force --force reboot   # double --force skips target ordering
```

If `systemctl reboot` itself hangs (it sometimes does because the shutdown path tries to stop the broken nvidia driver):

1. Switch to a TTY: `Ctrl+Alt+F3`, log in
2. Retry the `--force --force reboot`
3. If still stuck: SysRq REISUB (`Alt+SysRq+R`, `E`, `I`, `S`, `U`, `B`) if SysRq is enabled (`cat /proc/sys/kernel/sysrq` returns nonzero)
4. Last resort: hold the power button for 10 seconds. btrfs/ext4 with journaling will survive.

## Glossary

### Xid 79 — "GPU has fallen off the bus"

NVIDIA driver detected that the GPU stopped responding to PCIe register reads. On eGPU, this typically means the PCIe link or USB4 tunnel had a hiccup (Phoenix x1‑Gen1 bug, retimer training failure, marginal cable, etc.) and the GSP firmware bootstrap timed out.

After Xid 79 the driver **does not recover gracefully** — it holds a kernel spinlock that any subsequent CUDA call will try to acquire, deadlocking the calling process in uninterruptible sleep.

### NVRM cascade deadlock (after Xid 79)

The pattern that follows Xid 79:

1. Driver internal state is corrupt but the PCI device is still bound to `nvidia`
2. `nvidia-smi` (or any CUDA app) opens `/dev/nvidiactl` → enters the driver via ioctl
3. Driver calls into `_kgspRpcRecvPoll` waiting for a response from a dead GSP firmware
4. Process is now in **D state** (uninterruptible sleep), unkillable
5. Each subsequent `nvidia-smi` stacks on the same lock — D state count grows
6. `echo 1 > /sys/.../remove` and `modprobe -r nvidia` also deadlock (same `.remove()` callback)
7. Physical unplug fires `pciehp` surprise‑remove which calls the same `.remove()` → same deadlock

**Only a hard reboot recovers.** No user‑space workaround.

### RmInitAdapter failed

The driver's adapter init routine bailed. Distinct from Xid 79 — this is a softer failure mode where the driver lost its session (often after idle without `nvidia-persistenced`) and can't reattach. Companion log: `osInitNvMapping: Cannot attach gpu`.

Despite being "softer", the lockup pattern on subsequent CUDA calls is the same as Xid 79.

### Phoenix x1‑Gen1 bug

On AMD Family 19h Phoenix and derivatives, the USB4 PCIe tunnel sometimes negotiates `2.5 GT/s × 1 lane` instead of the full Gen3/Gen4 ×4 the link supports. At 0.25 GiB/s, anything requiring sustained PCIe traffic times out, including the GSP RPC bootstrap.

The bug is **intermittent** — re‑plugging often gives a clean negotiation. Root cause is hardware/firmware AMD‑side, no kernel fix available. See [references.md](references.md) for community tracking.

### GSP firmware

Since driver 535+, NVIDIA forces a small RISC-V firmware (GSP — *GPU System Processor*) on Turing and later GPUs that handles much of what used to be host‑driver work. It requires reliable, fast PCIe communication during bootstrap. **This is what fails first when the PCIe link is marginal**, hence the Phoenix x1‑Gen1 bug being so devastating.

### `nvidia-persistenced`

Userspace daemon that keeps `/dev/nvidia0` open continuously, preventing the driver from going through the open → init → close → reinit cycle between CUDA app invocations.

On eGPU this is **mandatory** — without it, the driver loses GSP session after idle and the next CUDA call lockups with `RmInitAdapter failed`. With it, the device stays attached perpetually.

### Compute‑only mode

The eGPU loads `nvidia.ko` + `nvidia-uvm.ko` (sufficient for CUDA) but NOT `nvidia-drm.ko` or `nvidia-modeset.ko`. No `/dev/dri/cardN` is created for the eGPU, so GNOME/mutter doesn't try to enumerate it as a render device. This sidesteps a class of mutter freeze bugs on hot‑plug.

See [why.md](why.md#why-compute-only) for the design rationale.

### D state (process)

Uninterruptible sleep — a process state in Linux where the process is waiting on a kernel operation that cannot be interrupted (typically waiting on hardware I/O). Cannot be killed even with `SIGKILL`. Shown as `D` in `ps aux` output. Visible in `egpu-diag.sh` as `Stuck nvidia D`.

### Persistence-M (in `nvidia-smi` output)

The `Persistence-M` column in `nvidia-smi` output reflects whether the GPU is in "persistence mode" — either via the legacy kernel persistence mode (set with `nvidia-smi -pm 1`) or via the modern `nvidia-persistenced` daemon. `On` is what you want.
