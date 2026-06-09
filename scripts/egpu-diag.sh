#!/bin/bash
# egpu-diag.sh — passive eGPU / Thunderbolt diagnostic
#
# Captures PCIe link state, retimer presence, Xid events, RmInitAdapter
# failures, NVRM init status, and nvidia-persistenced state, WITHOUT touching
# the nvidia driver (no nvidia-smi, no PCI remove, no module load/unload).
# Safe to run before/during/after eGPU plug — never triggers a cascade.
#
# Usage:
#   ./egpu-diag.sh              # one-shot snapshot
#   ./egpu-diag.sh --watch      # refresh every 2s until Ctrl+C
#   ./egpu-diag.sh --tail       # tail filtered kernel events live
#   ./egpu-diag.sh --log FILE   # append snapshot row to FILE (markdown table)

set -u
WATCH=false
TAIL=false
LOG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH=true; shift ;;
        --tail)  TAIL=true; shift ;;
        --log)   LOG_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ---------- helpers ----------
nvidia_pci_addr() {
    # First NVIDIA VGA / 3D function. Empty if no eGPU on bus.
    lspci -d 10de:: 2>/dev/null | awk '/VGA compatible|3D controller/ {print $1; exit}'
}

link_status() {
    local addr="$1"
    [[ -z "$addr" ]] && { echo "no-device|no-device"; return; }
    local sysfs="/sys/bus/pci/devices/0000:${addr}"
    local speed width
    speed=$(cat "$sysfs/current_link_speed" 2>/dev/null || echo "?")
    width=$(cat "$sysfs/current_link_width" 2>/dev/null || echo "?")
    echo "${speed}|x${width}"
}

link_verdict() {
    local speed="$1" width="$2"
    case "$speed" in
        "16.0 GT/s PCIe") [[ "$width" == "x4" ]] && echo "OK-Gen4x4" || echo "WARN-Gen4-narrow" ;;
        "8.0 GT/s PCIe")  [[ "$width" == "x4" ]] && echo "OK-Gen3x4"  || echo "WARN-Gen3-narrow" ;;
        "5.0 GT/s PCIe")  echo "DEGRADED-Gen2" ;;
        "2.5 GT/s PCIe")  echo "BUG-Gen1-AMD-Phoenix" ;;
        no-device)        echo "no-device" ;;
        *)                echo "unknown:$speed" ;;
    esac
}

xid_recent() {
    # Count NVRM Xid events in the last 5 minutes.
    journalctl -k --since "5 minutes ago" --no-pager 2>/dev/null \
        | grep -c 'NVRM: Xid' 2>/dev/null || true
}

rminit_failures() {
    # Count "RmInitAdapter failed" or "Cannot attach gpu" events in last 5min.
    # These signal a silent driver session loss (no Xid logged but device
    # state is corrupt). Equally fatal as Xid 79 — the next CUDA call will
    # deadlock in a spinlock.
    journalctl -k --since "5 minutes ago" --no-pager 2>/dev/null \
        | grep -cE 'RmInitAdapter failed|Cannot attach gpu' 2>/dev/null || true
}

nvrm_loaded() {
    journalctl -k -b 0 --no-pager 2>/dev/null \
        | grep -q 'NVRM: loading' && echo yes || echo no
}

stuck_nvidia_procs() {
    # Processes in uninterruptible sleep with nvidia in cmd. These are the
    # canary for the "Xid 79 → spinlock taken forever" deadlock.
    ps -eo stat,cmd 2>/dev/null \
        | awk '/^D/ && /nvidia/ {n++} END {print (n+0)}'
}

retimer_count() {
    # Active TB retimers (devices with ':' in their name, e.g. 0-0:2.1).
    # Routers (0-0, 1-0, 0-2, etc.) don't have ':'.
    find /sys/bus/thunderbolt/devices -maxdepth 1 -name '*:*' 2>/dev/null \
        | wc -l
}

tb_devices_connected() {
    # bolt-known external devices currently connected.
    command -v boltctl &>/dev/null || { echo 0; return; }
    boltctl list 2>/dev/null | awk '/^ \* / {n++} END {print (n+0)}'
}

persistenced_status() {
    if ! systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
        echo "not-installed"
    elif systemctl is-active nvidia-persistenced.service &>/dev/null; then
        echo "active"
    else
        echo "inactive"
    fi
}

driver_flavor() {
    # Detect open vs closed NVIDIA kmod via modinfo license.
    # Open is "Dual MIT/GPL"; closed is "NVIDIA".
    local lic
    lic=$(modinfo -F license nvidia 2>/dev/null)
    case "$lic" in
        *MIT*|*GPL*) echo "open" ;;
        NVIDIA)      echo "closed" ;;
        "")          echo "none" ;;
        *)           echo "unknown" ;;
    esac
}

gsp_status() {
    # Compose a one-line status for the GSP firmware. The detail matters
    # because GSP can only be turned off with the closed kmod — and that's
    # often what users tweak after hitting WPR2 / GSP-bootstrap cascades.
    local flavor; flavor=$(driver_flavor)
    local rt=""
    [[ -f /sys/module/nvidia/parameters/EnableGpuFirmware ]] \
        && rt=$(cat /sys/module/nvidia/parameters/EnableGpuFirmware 2>/dev/null)
    local conf_present=false
    grep -lq 'NVreg_EnableGpuFirmware=0' /etc/modprobe.d/*.conf 2>/dev/null && conf_present=true

    case "$flavor" in
        none)
            echo "no nvidia driver"
            ;;
        open)
            if $conf_present; then
                echo "on (open kmod — NVreg_EnableGpuFirmware=0 in modprobe.d is ignored)"
            else
                echo "on (open kmod, always)"
            fi
            ;;
        closed)
            if [[ "$rt" == "0" ]]; then
                echo "off (closed kmod, NVreg_EnableGpuFirmware=0 active)"
            elif [[ "$rt" == "1" ]]; then
                echo "on (closed kmod, default)"
            elif $conf_present; then
                echo "off-pending (closed kmod, config present, module not yet loaded)"
            else
                echo "on-pending (closed kmod, module not yet loaded)"
            fi
            ;;
        *)
            echo "unknown (flavor=$flavor)"
            ;;
    esac
}

# ---------- snapshot ----------
snapshot() {
    local ts addr link_pair speed width verdict
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    addr=$(nvidia_pci_addr)
    link_pair=$(link_status "$addr")
    speed="${link_pair%|*}"
    width="${link_pair#*|}"
    verdict=$(link_verdict "$speed" "$width")
    local xids rminit stuck nvrm retimers tb_conn persist flavor gsp
    xids=$(xid_recent)
    rminit=$(rminit_failures)
    stuck=$(stuck_nvidia_procs)
    nvrm=$(nvrm_loaded)
    retimers=$(retimer_count)
    tb_conn=$(tb_devices_connected)
    persist=$(persistenced_status)
    flavor=$(driver_flavor)
    gsp=$(gsp_status)

    # Safe-to-smi gate:
    #   - link must be OK-*
    #   - no Xid events in last 5min
    #   - no RmInitAdapter failures in last 5min
    #   - no nvidia process stuck in D state
    #   - GPU actually on bus
    local safe="NO"
    case "$verdict" in
        OK-*)
            if [[ "$xids" -eq 0 && "$rminit" -eq 0 && "$stuck" -eq 0 && -n "$addr" ]]; then
                safe="YES"
            fi
            ;;
    esac

    if [[ -n "$LOG_FILE" ]]; then
        if [[ ! -f "$LOG_FILE" ]]; then
            printf '| time | pci | link | width | verdict | xid5m | rminit5m | stuck | retimers | tb_conn | nvrm | persist | flavor | gsp | safe |\n' >> "$LOG_FILE"
            printf '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n' >> "$LOG_FILE"
        fi
        printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
            "$ts" "${addr:-—}" "$speed" "$width" "$verdict" \
            "$xids" "$rminit" "$stuck" "$retimers" "$tb_conn" "$nvrm" "$persist" \
            "$flavor" "$gsp" "$safe" \
            >> "$LOG_FILE"
        return
    fi

    cat <<EOF
eGPU diag — $ts
  PCI addr           : ${addr:-not present on bus}
  Link speed         : $speed
  Link width         : $width
  Verdict            : $verdict
  Xid (last 5min)    : $xids
  RmInit fail (5min) : $rminit
  Stuck nvidia D     : $stuck
  TB retimers        : $retimers
  TB connected       : $tb_conn
  NVRM loaded        : $nvrm
  nvidia-persistenced: $persist
  Driver flavor      : $flavor
  GSP firmware       : $gsp
  Safe nvidia-smi    : $safe
EOF
}

# ---------- live tail ----------
tail_relevant() {
    echo "Tailing kernel events (Ctrl+C to stop). Filtered for TB/PCIe/nvidia/Xid:"
    journalctl -kf --no-pager 2>&1 \
        | grep --line-buffered -iE \
          'thunderbolt [0-9]-|retimer|pciehp|available PCIe|nvidia [0-9]|NVRM|Xid|RmInit|Cannot attach|amdgpu.*reset'
}

# ---------- entry ----------
if $TAIL; then
    tail_relevant
elif $WATCH; then
    while true; do
        clear
        snapshot
        sleep 2
    done
else
    snapshot
fi
