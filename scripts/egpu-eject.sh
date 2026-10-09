#!/bin/bash
# egpu-eject.sh — detach the NVIDIA eGPU cleanly before unplugging it.
#
# Pulling the cable while nvidia.ko is still bound to the GPU is a surprise
# removal: the driver finds the device gone ("NVRM: GPU ... has fallen off the
# bus", Xid 154) and, if anything was using the GPU, it can deadlock. Ejecting
# first lets the driver detach while the GPU is still there:
#
#   1. refuse if nvidia processes are stuck (D state) or if any program
#      other than nvidia-persistenced still has /dev/nvidia* open
#   2. stop nvidia-persistenced
#   3. PCI-remove the GPU's functions (HDMI audio first, then the GPU): the
#      driver's remove() runs on a device that still answers
#   4. deauthorize the Thunderbolt/USB4 device, which tears the PCIe tunnel
#      down in order (only when the domain supports it and the eGPU is the
#      only authorized peripheral, to avoid cutting a dock)
#   5. check the kernel log for Xid / "fallen off the bus" since step 2
#
# Then unplug the cable and switch the enclosure off.
#
# Usage:
#   ./egpu-eject.sh             # interactive
#   ./egpu-eject.sh --yes       # no confirmation
#   ./egpu-eject.sh --dry-run   # checks and plan only, changes nothing
#   ./egpu-eject.sh --undo      # changed your mind: re-authorize + PCI rescan

set -uo pipefail

MODE=eject
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)  ASSUME_YES=true; shift ;;
        --dry-run) MODE=dry; shift ;;
        --undo)    MODE=undo; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1 (see --help)" >&2; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; B=""; N=""
fi
say()  { printf '%s\n' "$*"; }
hdr()  { printf "\n${B}== %s ==${N}\n" "$*"; }
ok()   { printf "  ${G}✓${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }
bad()  { printf "  ${R}✗${N} %s\n" "$*"; }
confirm() {
    $ASSUME_YES && return 0
    local reply; read -rp "${1:-Proceed?} [y/N] " reply
    [[ "$reply" =~ ^[yY]$ ]]
}

# Full PCI address of the first NVIDIA VGA / 3D function, e.g. 0000:06:00.0
gpu_addr() {
    local out; out=$(lspci -D -d 10de: 2>/dev/null || true)
    awk '/VGA compatible|3D controller/ {print $1; exit}' <<<"$out"
}

# Authorized Thunderbolt/USB4 peripherals (not host routers, not retimers).
tb_peripherals() {
    local d n
    for d in /sys/bus/thunderbolt/devices/*; do
        n=$(basename "$d")
        [[ "$n" =~ ^[0-9]+-[1-9][0-9]*$ ]] || continue
        [[ "$(cat "$d/authorized" 2>/dev/null)" == 1 ]] || continue
        echo "$d"
    done
}

# Thunderbolt peripherals that are connected but not authorized (after an eject).
tb_deauthorized() {
    local d n
    for d in /sys/bus/thunderbolt/devices/*; do
        n=$(basename "$d")
        [[ "$n" =~ ^[0-9]+-[1-9][0-9]*$ ]] || continue
        [[ "$(cat "$d/authorized" 2>/dev/null)" == 0 ]] || continue
        echo "$d"
    done
}

tb_label() { printf '%s %s (%s)' "$(cat "$1/vendor_name" 2>/dev/null)" "$(cat "$1/device_name" 2>/dev/null)" "$(basename "$1")"; }

# Domain of a TB device supports deauthorization (writing 0 to authorized)?
tb_can_deauthorize() {
    local dom; dom="domain${1##*/}"; dom="${dom%%-*}"
    [[ "$(cat "/sys/bus/thunderbolt/devices/$dom/deauthorization" 2>/dev/null)" == 1 ]]
}

# ---------- undo ----------
if [[ "$MODE" == undo ]]; then
    hdr "Undo eject"
    mapfile -t deauth < <(tb_deauthorized)
    for d in "${deauth[@]}"; do
        say "  Re-authorizing $(tb_label "$d")..."
        echo 1 | sudo tee "$d/authorized" >/dev/null && ok "authorized" || bad "could not re-authorize $d"
    done
    say "  Rescanning the PCI bus..."
    echo 1 | sudo tee /sys/bus/pci/rescan >/dev/null
    sleep 3
    if [[ -n "$(gpu_addr)" ]]; then
        ok "GPU back on the bus: $(gpu_addr) (nvidia-persistenced starts on bind)"
    else
        bad "GPU not found after rescan — unplug, power-cycle the enclosure, plug again"
        exit 1
    fi
    exit 0
fi

# ---------- checks ----------
hdr "Checks"
gpu=$(gpu_addr)
if [[ -z "$gpu" ]]; then
    ok "no NVIDIA GPU on the bus — nothing to eject, safe to unplug"
    exit 0
fi
slot="${gpu%.*}"
ok "eGPU at $gpu"

stuck=$(ps -eo stat,cmd 2>/dev/null | awk '/^D/ && /nvidia/ {n++} END {print n+0}')
if (( stuck > 0 )); then
    bad "$stuck nvidia process(es) in D state: the driver is stuck."
    bad "Do NOT eject. Run egpu-recover.sh, or power-cycle the enclosure / reboot."
    exit 1
fi
ok "no nvidia process in D state"

# Who has /dev/nvidia* open? Seeing root's and other users' processes needs
# root. Without sudo (dry run), say the check is partial instead of claiming
# that nothing uses the GPU.
scan_scope=full
if sudo -n true 2>/dev/null || { [[ "$MODE" != dry ]] && sudo -v; }; then
    users=$(sudo find /proc/[0-9]*/fd -lname '/dev/nvidia*' -printf '%h\n' 2>/dev/null \
            | cut -d/ -f3 | sort -u || true)
else
    scan_scope=partial
    users=$(find /proc/[0-9]*/fd -lname '/dev/nvidia*' -printf '%h\n' 2>/dev/null \
            | cut -d/ -f3 | sort -u || true)
fi
blocking=()
for pid in $users; do
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || continue
    [[ "$comm" == nvidia-persiste* ]] && continue
    blocking+=("$pid ($comm)")
done
if (( ${#blocking[@]} > 0 )); then
    bad "Programs still using the GPU — close them first:"
    for b in "${blocking[@]}"; do say "      $b"; done
    exit 1
fi
if [[ "$scan_scope" == full ]]; then
    ok "no program is using the GPU (nvidia-persistenced aside)"
else
    warn "no program of yours is using the GPU (root processes not checked: no sudo)"
fi

mapfile -t periph < <(tb_peripherals)
tb=""
if (( ${#periph[@]} == 1 )) && tb_can_deauthorize "${periph[0]}"; then
    tb="${periph[0]}"
    ok "Thunderbolt device: $(tb_label "$tb") — will be deauthorized"
elif (( ${#periph[@]} > 1 )); then
    warn "${#periph[@]} authorized Thunderbolt devices: not deauthorizing (could cut a dock)"
else
    warn "Thunderbolt deauthorization unavailable: PCI remove only"
fi

functions=()
for f in /sys/bus/pci/devices/"$slot".*; do
    [[ -e "$f" ]] && functions+=("$(basename "$f")")
done
# Secondary functions (HDMI audio, USB-C) depend on function 0: remove them first.
mapfile -t functions < <(printf '%s\n' "${functions[@]}" | sort -r)

hdr "Plan"
say "  1. stop nvidia-persistenced"
say "  2. PCI remove: ${functions[*]}"
[[ -n "$tb" ]] && say "  3. deauthorize $(tb_label "$tb")"
if [[ "$MODE" == dry ]]; then
    say ""; say "  (dry run — nothing changed)"
    exit 0
fi
confirm "Eject the eGPU now?" || exit 1

# ---------- eject ----------
since=$(date '+%Y-%m-%d %H:%M:%S')
hdr "Ejecting"
if systemctl is-active --quiet nvidia-persistenced.service; then
    sudo systemctl stop nvidia-persistenced.service && ok "nvidia-persistenced stopped"
fi

for f in "${functions[@]}"; do
    [[ -e "/sys/bus/pci/devices/$f" ]] || continue
    # timeout cannot kill a write stuck in the kernel, but it tells us so.
    if timeout 20 sudo sh -c "echo 1 > /sys/bus/pci/devices/$f/remove"; then
        ok "removed $f"
    else
        bad "removing $f timed out — the driver is stuck. Do not unplug; run egpu-recover.sh."
        exit 1
    fi
done

if [[ -n "$tb" ]]; then
    if echo 0 | sudo tee "$tb/authorized" >/dev/null; then
        ok "Thunderbolt tunnel closed ($(tb_label "$tb") deauthorized)"
    else
        warn "deauthorization refused — the PCI remove alone is enough to unplug"
    fi
fi

# ---------- verify ----------
sleep 1
hdr "Verify"
if [[ -n "$(gpu_addr)" ]]; then
    bad "GPU still on the bus"; exit 1
fi
ok "GPU detached from the driver and the bus"
klog=$(journalctl -k --since "$since" --no-pager 2>/dev/null || true)
if grep -qE 'NVRM: Xid|fallen off the bus' <<<"$klog"; then
    warn "kernel reported an Xid during the eject:"
    grep -E 'NVRM: Xid|fallen off the bus' <<<"$klog" | sed 's/^/      /'
else
    ok "no Xid, no 'fallen off the bus'"
fi

say ""
say "${G}${B}Safe to unplug:${N} pull the cable, then switch the enclosure off."
say "Changed your mind? $0 --undo"
