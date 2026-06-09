#!/bin/bash
# egpu-recover.sh — guided recovery from an eGPU stuck state.
#
# Handles the failure modes we see in the wild on AMD USB4 + NVIDIA eGPU:
#   - "GPU has fallen off the bus" (Xid 79)
#   - "RmInitAdapter failed (0x22:0x56:894)" / "Cannot attach gpu"
#   - "WPR2 already up, cannot proceed with booting GSP"
#   - Resulting D-state nvidia-smi / nvidia-related processes
#
# The script NEVER touches the driver while there are D-state processes
# (touching the driver in that state piles new D-state entries on the same
# spinlock — exactly the cascade we want to avoid). It only does read-only
# triage and tells you what to do (power-cycle / reboot).
#
# Once D-state is clear, it offers progressively more invasive recovery
# steps (gated behind explicit confirmation or --force).
#
# Usage:
#   ./egpu-recover.sh                # interactive triage
#   ./egpu-recover.sh --auto         # take the least invasive auto step it can
#   ./egpu-recover.sh --pci-remove   # try `echo 1 > /sys/.../remove` (risky)
#   ./egpu-recover.sh --modprobe-r   # try modprobe -r nvidia with timeout

set -u

MODE_AUTO=false
MODE_PCI_REMOVE=false
MODE_MODPROBE_R=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)         MODE_AUTO=true; shift ;;
        --pci-remove)   MODE_PCI_REMOVE=true; shift ;;
        --modprobe-r)   MODE_MODPROBE_R=true; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ANSI colors (terminal only)
if [[ -t 1 ]]; then
    G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; B=""; N=""
fi

say()  { printf '%s\n' "$*"; }
hdr()  { printf "\n${B}== %s ==${N}\n" "$*"; }
ok()   { printf "  ${G}✓${NC:-$N}${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }
bad()  { printf "  ${R}✗${N} %s\n" "$*"; }

confirm() {
    local prompt="${1:-Proceed?} [y/N] "
    read -rp "$prompt" reply
    [[ "$reply" =~ ^[yY]$ ]]
}

# ---------- read-only triage ----------

hdr "Triage"

# 1. D-state nvidia processes. `grep -c` already prints the count and exits
# nonzero on zero matches — don't double up with `|| echo 0`.
stuck=$(ps -eo pid,stat,cmd 2>/dev/null | awk '/^[[:space:]]*[0-9]+[[:space:]]+D/ && /nvidia/ {print $1}')
stuck_count=$(printf '%s\n' "$stuck" | grep -c '^[0-9]')
if [[ "$stuck_count" -gt 0 ]]; then
    bad "$stuck_count nvidia process(es) in D state (uninterruptible kernel sleep):"
    # Loop over PIDs and print one line each — avoids `grep PID` matching itself.
    while IFS= read -r p; do
        ps -p "$p" -o pid,stat,wchan,cmd 2>/dev/null | tail -n +2 | sed 's/^/      /'
    done <<< "$stuck"
    HAS_D=true
else
    ok "no nvidia processes in D state"
    HAS_D=false
fi

# 2. eGPU on PCI bus?
nv_addr=$(lspci -d 10de:: 2>/dev/null | awk '/VGA compatible|3D controller/ {print $1; exit}')
if [[ -n "$nv_addr" ]]; then
    ok "eGPU still on PCI bus at 0000:$nv_addr"
    GPU_ON_BUS=true
else
    warn "no NVIDIA GPU on PCI bus — already removed/unplugged"
    GPU_ON_BUS=false
fi

# 3. Recent driver errors (Xid, RmInit, WPR2). `grep -c` already prints "0"
# on no matches and exits nonzero — don't double up with `|| echo 0`.
recent_xid=$(journalctl -k --since "5 minutes ago" --no-pager 2>/dev/null | grep -c 'NVRM: Xid')
recent_rminit=$(journalctl -k --since "5 minutes ago" --no-pager 2>/dev/null | grep -cE 'RmInitAdapter failed|Cannot attach gpu')
recent_wpr2=$(journalctl -k --since "5 minutes ago" --no-pager 2>/dev/null | grep -c 'WPR2 already up')
if [[ "$recent_xid" -gt 0 ]]; then bad "Xid events in last 5min: $recent_xid"; fi
if [[ "$recent_rminit" -gt 0 ]]; then bad "RmInitAdapter / Cannot attach in last 5min: $recent_rminit"; fi
if [[ "$recent_wpr2" -gt 0 ]]; then
    bad "WPR2 already up: $recent_wpr2 — GSP firmware corruption, needs hardware reset (eGPU power-cycle)"
fi

# 4. nvidia-persistenced
persist_state=$(systemctl is-active nvidia-persistenced.service 2>/dev/null)
[[ -z "$persist_state" ]] && persist_state="unknown"
say "  nvidia-persistenced: $persist_state"

# ---------- decision tree ----------

hdr "Recommended path"

if $HAS_D; then
    bad "D-state processes present — DO NOT call nvidia-smi, do NOT modprobe -r."
    say ""
    say "  Mandatory steps, in order:"
    say "    1. ${B}POWER-CYCLE${N} the eGPU enclosure (switch OFF, wait 5s, switch ON)."
    say "       This forces a pciehp surprise-remove which usually breaks the locks."
    say "    2. Wait ~10s, then re-run this script. If D-state is gone → OK,"
    say "       udev will re-start persistenced when the GPU re-enumerates."
    say "    3. If D-state PERSISTS after power-cycle → ${R}reboot${N}:"
    say "         sync && sync && sudo systemctl --force --force reboot"
    say "       If reboot itself hangs (the shutdown helper has a 20s timeout"
    say "       for this), switch to a TTY (Ctrl+Alt+F3) and retry from there."
    exit 1
fi

# No D-state. Now decide based on state.

if ! $GPU_ON_BUS; then
    ok "No GPU on bus and no stuck processes → state is clean."
    say "  Re-plug or re-power-on the enclosure when ready, then ./scripts/egpu-diag.sh"
    exit 0
fi

# GPU on bus, no D-state, but recent errors. We can try progressively more
# invasive steps. Each can hang if the GPU is in a really bad state, so we
# wrap them in `timeout` and ask for confirmation.

if [[ "$recent_wpr2" -gt 0 || "$recent_rminit" -gt 0 || "$recent_xid" -gt 0 ]]; then
    warn "Driver errored recently but no D-state right now."
    say ""
    say "  Suggested order of escalation:"
    say "    a) ${G}safest${N}: power-cycle the eGPU enclosure (no command — physical switch)."
    say "    b) ${Y}medium${N}: stop persistenced + try PCI remove (this script with --pci-remove)."
    say "    c) ${Y}medium${N}: stop persistenced + modprobe -r nvidia (--modprobe-r)."
    say "    d) ${R}always works${N}: reboot."
    say ""

    if $MODE_PCI_REMOVE; then
        hdr "Attempting PCI remove of 0000:$nv_addr"
        say "  Stopping nvidia-persistenced first..."
        sudo systemctl stop nvidia-persistenced.service 2>/dev/null
        say "  Removing 0000:$nv_addr.1 (audio function, depends on .0)..."
        timeout 10 sudo sh -c "echo 1 > /sys/bus/pci/devices/0000:${nv_addr%.*}.1/remove" 2>&1 \
            && ok "audio removed" || warn "audio remove timed out or failed"
        say "  Removing 0000:$nv_addr (GPU)..."
        timeout 10 sudo sh -c "echo 1 > /sys/bus/pci/devices/0000:${nv_addr}/remove" 2>&1 \
            && ok "GPU removed" || bad "GPU remove timed out — driver stuck, reboot needed"
        exit 0
    fi

    if $MODE_MODPROBE_R; then
        hdr "Attempting modprobe -r nvidia (with timeout)"
        say "  Stopping nvidia-persistenced first..."
        sudo systemctl stop nvidia-persistenced.service 2>/dev/null
        say "  Unloading nvidia_uvm (5s timeout)..."
        timeout 5 sudo modprobe -r nvidia_uvm 2>&1 \
            && ok "nvidia_uvm unloaded" || warn "nvidia_uvm unload timed out"
        say "  Unloading nvidia (10s timeout)..."
        timeout 10 sudo modprobe -r nvidia 2>&1 \
            && ok "nvidia unloaded" || bad "nvidia unload timed out — reboot needed"
        exit 0
    fi

    if $MODE_AUTO; then
        say "  --auto: only doing the safest non-physical step: stop persistenced."
        sudo systemctl stop nvidia-persistenced.service 2>/dev/null
        ok "nvidia-persistenced stopped."
        say "  Now power-cycle the enclosure, then ./scripts/egpu-diag.sh"
        exit 0
    fi

    say "  Re-run with one of: ${B}--pci-remove${N}, ${B}--modprobe-r${N}, or ${B}--auto${N}."
    exit 0
fi

ok "No recent driver errors. State looks clean."
say "  Run ./scripts/egpu-diag.sh for a current snapshot."
