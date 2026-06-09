#!/bin/bash
# shutdown-helper.sh — cleanly tear down NVIDIA eGPU before system shutdown.
#
# Invoked by /etc/systemd/system/nvidia-egpu-shutdown.service. Not meant to
# be run interactively. Installed by setup-compute.sh to:
#   /usr/local/lib/amd-usb4-egpu-toolkit/shutdown-helper.sh
#
# Logic, in order:
#   1. Stop nvidia-persistenced cleanly (release /dev/nvidia0)
#   2. If no NVIDIA module is loaded, exit early (nothing to do)
#   3. Unload nvidia_uvm (depends on nvidia.ko), with timeout
#   4. Unload nvidia.ko, with timeout
#
# Each unload is wrapped in `timeout 5s`. If a module unload hangs (usually
# because the driver is already stuck in the Xid 79 / RmInitAdapter
# spinlock), we give up after the timeout — the goal is to make the COMMON
# case smoother, not to magically rescue an already-broken state. systemd
# will continue the shutdown either way.
#
# All output goes to syslog (journald) so it shows up in the next boot's
# journal even though the journal is being torn down concurrently.

set -u

LOG() { logger -t nvidia-egpu-shutdown "$@"; }

# Lesson from the 2026-06-09 hung shutdown: if there are already D-state
# nvidia processes when shutdown starts, `modprobe -r nvidia*` will also
# enter D state on the same kernel spinlock. `timeout` cannot kill a process
# in uninterruptible kernel sleep — neither can SIGTERM, SIGKILL, or
# systemd's final-watchdog. The kernel keeps the modprobe alive, systemd
# eventually unblocks but the rest of shutdown freezes anyway.
#
# So: detect the bad state up front and EXIT EARLY without attempting any
# unload. The shutdown will still likely hang on the final module-unload
# step, but we won't have added our own contribution to the pile of stuck
# processes — and the journal will clearly show that we knew and skipped.
stuck_count=$(ps -eo stat,cmd 2>/dev/null | awk '/^D/ && /nvidia/ {n++} END {print n+0}')
if [[ "${stuck_count:-0}" -gt 0 ]]; then
    LOG "ABORTING: $stuck_count nvidia process(es) already in D state — driver is stuck."
    LOG "         Any modprobe -r would also deadlock on the same spinlock."
    LOG "         Shutdown will probably need a hard power-cycle (driver bug)."
    LOG "         No unload attempted. See egpu-postmortem.sh after next boot."
    exit 0
fi

unload_with_timeout() {
    local module="$1"
    local timeout_s="${2:-5}"
    LOG "Unloading $module (timeout ${timeout_s}s)..."
    if timeout "$timeout_s" modprobe -r "$module" 2>&1 | logger -t nvidia-egpu-shutdown; then
        LOG "$module unloaded cleanly"
        return 0
    else
        # `timeout` returned non-zero → either the deadline hit (and we sent
        # SIGTERM/SIGKILL, but if modprobe is in D state those are ignored)
        # or modprobe exited with an error. Either way: stop trying.
        LOG "$module unload failed or timed out (driver likely stuck — not retrying)"
        return 1
    fi
}

# 1. Stop nvidia-persistenced (releases /dev/nvidia0 → drops a refcount on
#    nvidia.ko). systemctl is-active returns 0 only when truly active; the
#    drop-in's ConditionPathExists may already have set it inactive if the
#    eGPU was unplugged before shutdown.
if systemctl is-active nvidia-persistenced.service &>/dev/null; then
    LOG "Stopping nvidia-persistenced..."
    systemctl stop nvidia-persistenced.service
fi

# 2. Fast path: if nvidia.ko was never loaded this boot (no eGPU plugged),
#    nothing else to do.
if ! lsmod | grep -q '^nvidia '; then
    LOG "nvidia.ko not loaded — nothing to clean up"
    exit 0
fi

# 3. Unload nvidia_uvm first (depends on nvidia.ko). If this hangs, we bail
#    instead of also trying nvidia — piling a second stuck modprobe just
#    makes the shutdown timeout worse.
if lsmod | grep -q '^nvidia_uvm'; then
    if ! unload_with_timeout nvidia_uvm 5; then
        LOG "skipping nvidia.ko unload because nvidia_uvm was stuck"
        exit 0
    fi
fi

# 4. Unload nvidia.ko
unload_with_timeout nvidia 10

LOG "shutdown-helper.sh done"
exit 0
