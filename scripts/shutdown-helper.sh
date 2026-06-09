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

unload_with_timeout() {
    local module="$1"
    local timeout_s="${2:-5}"
    LOG "Unloading $module (timeout ${timeout_s}s)..."
    if timeout "$timeout_s" modprobe -r "$module" 2>&1 | logger -t nvidia-egpu-shutdown; then
        LOG "$module unloaded cleanly"
        return 0
    else
        LOG "$module unload timed out or failed (driver likely stuck — giving up)"
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

# 3. Unload nvidia_uvm first (depends on nvidia.ko)
if lsmod | grep -q '^nvidia_uvm'; then
    unload_with_timeout nvidia_uvm 5
fi

# 4. Unload nvidia.ko
unload_with_timeout nvidia 10

LOG "shutdown-helper.sh done"
exit 0
