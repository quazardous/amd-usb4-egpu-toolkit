#!/bin/bash
# gsp-off.sh — opt-in workaround: disable NVIDIA GSP firmware.
#
# Sets the `NVreg_EnableGpuFirmware=0` module parameter so the driver doesn't
# bootstrap the on-GPU RISC-V firmware (GSP). This bypasses the whole class
# of failures rooted in GSP RPC: Xid 79 from GSP bootstrap timeout on slow
# PCIe links (Phoenix x1-Gen1), `WPR2 already up`, `kgspWaitForRmInitDone`
# spinlock, etc.
#
# IMPORTANT CAVEATS — read before enabling:
#
# 1. Only works with the PROPRIETARY (closed) NVIDIA kernel module
#    (`akmod-nvidia` on Fedora / RPM Fusion, `nvidia-dkms` on Arch). The OPEN
#    module ignores this parameter — GSP is mandatory there. The script
#    detects which driver is loaded and warns if it can't take effect.
#    Since branch 615, NVIDIA's own CUDA repositories ship the open module
#    only; RPM Fusion still ships the closed one but builds open for
#    Turing+ unless told otherwise (see the 'enable' warning).
#
# 2. NVIDIA marked this option as deprecated for Turing+. Verified working
#    on the closed 615.71.09 module (RTX 3090, 2026-10-09: EnableGpuFirmware=0,
#    nvidia-smi reports GSP Firmware Version N/A), but it is scheduled for
#    removal in a future release. Treat as a tactical workaround, not a
#    long-term fix.
#
# 3. Without GSP, clock/power management runs CPU-side. Slight perf hit on
#    sustained compute. Marginal for Ollama / inference; more visible for
#    heavy training.
#
# 4. The AMD Phoenix x1-Gen1 PCIe bug is independent — GSP-off bypasses the
#    GSP RPC timeout symptom, but very large data transfers during driver
#    init can still time out on a x1-Gen1 link.
#
# Usage:
#   ./gsp-off.sh enable    Install /etc/modprobe.d/nvidia-gsp-off.conf + regen initramfs
#   ./gsp-off.sh disable   Remove the file + regen initramfs (revert to GSP-on default)
#   ./gsp-off.sh status    Show current state
#
# After enable/disable: reboot for the change to take effect.

set -u

CONF=/etc/modprobe.d/nvidia-gsp-off.conf
ACTION="${1:-status}"

if [[ -t 1 ]]; then
    G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[1;33m'; B=$'\033[1m'; N=$'\033[0m'
else
    G=""; R=""; Y=""; B=""; N=""
fi

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf "${G}[✓]${N} %s\n" "$*"; }
warn() { printf "${Y}[!]${N} %s\n" "$*" >&2; }
err()  { printf "${R}[✗]${N} %s\n" "$*" >&2; }

# ---------- driver detection ----------
detect_driver_flavor() {
    # Reads modinfo of the installed nvidia.ko (whether currently loaded or not).
    # Open kmod license is "Dual MIT/GPL"; closed is "NVIDIA".
    local lic
    lic=$(modinfo -F license nvidia 2>/dev/null)
    case "$lic" in
        *MIT*|*GPL*) echo "open" ;;
        NVIDIA)      echo "closed" ;;
        "")          echo "none" ;;
        *)           echo "unknown:$lic" ;;
    esac
}

regen_initramfs() {
    if command -v dracut &>/dev/null; then
        log "Regenerating initramfs (dracut -f)..."
        sudo dracut -f && ok "initramfs regenerated (dracut)"
    elif command -v update-initramfs &>/dev/null; then
        log "Regenerating initramfs (update-initramfs -u)..."
        sudo update-initramfs -u && ok "initramfs regenerated (update-initramfs)"
    elif command -v mkinitcpio &>/dev/null; then
        log "Regenerating initramfs (mkinitcpio -P)..."
        sudo mkinitcpio -P && ok "initramfs regenerated (mkinitcpio)"
    else
        warn "Unknown initramfs tool. Regenerate manually before reboot."
    fi
}

# ---------- status ----------
do_status() {
    local flavor; flavor=$(detect_driver_flavor)
    printf "${B}NVIDIA driver flavor:${N} %s\n" "$flavor"
    case "$flavor" in
        open)    warn "open kmod ignores NVreg_EnableGpuFirmware. GSP-off has no effect on this driver. Switch to the closed kmod (see 'gsp-off.sh enable' for per-distro steps)." ;;
        closed)  ok "closed kmod respects NVreg_EnableGpuFirmware." ;;
        none)    warn "no NVIDIA kernel module installed yet." ;;
    esac
    echo ""

    if [[ -f "$CONF" ]]; then
        printf "${B}Config file ${CONF}:${N} ${G}present${N}\n"
        sed 's/^/    /' "$CONF"
    else
        printf "${B}Config file ${CONF}:${N} not present (GSP-on, NVIDIA default)\n"
    fi
    echo ""

    # Runtime state, only meaningful while the module is loaded. The closed
    # module exposes NVreg_* options in /proc/driver/nvidia/params, not in
    # /sys/module/nvidia/parameters/.
    local rt=""
    if [[ -r /proc/driver/nvidia/params ]]; then
        rt=$(awk -F': ' '$1=="EnableGpuFirmware"{print $2; exit}' /proc/driver/nvidia/params)
    elif [[ -f /sys/module/nvidia/parameters/EnableGpuFirmware ]]; then
        rt=$(cat /sys/module/nvidia/parameters/EnableGpuFirmware)
    fi
    if [[ -n "$rt" ]]; then
        printf "${B}Runtime EnableGpuFirmware:${N} %s\n" "$rt"
    else
        printf "${B}Runtime EnableGpuFirmware:${N} (nvidia module not loaded)\n"
    fi
}

# ---------- enable ----------
do_enable() {
    local flavor; flavor=$(detect_driver_flavor)
    case "$flavor" in
        open)
            warn "The currently installed NVIDIA kmod is the OPEN variant."
            warn "It will IGNORE NVreg_EnableGpuFirmware=0 (GSP is mandatory there)."
            warn "Switch to the closed driver first:"
            warn "    Fedora (RPM Fusion): akmod-nvidia picks open vs closed AT BUILD TIME and"
            warn "      chooses OPEN for Turing+ GPUs (nvidia-kmod-noopen-checks). Force closed:"
            warn "        echo '%_without_kmod_nvidia_detect 1' | sudo tee /etc/rpm/macros.nvidia-kmod-closed"
            warn "        sudo dnf swap akmod-nvidia-open akmod-nvidia   # if the -open package is installed"
            warn "        sudo akmods --force --rebuild --akmod nvidia --kernels \$(uname -r)"
            warn "      then reinstall the rebuilt RPM (akmods may report Successful without"
            warn "      installing it): sudo dnf reinstall /var/cache/akmods/nvidia/kmod-nvidia-\$(uname -r)-*.rpm"
            warn "    Fedora (NVIDIA CUDA repo): no closed module since branch 615 — use RPM Fusion."
            warn "    Ubuntu:                    sudo apt install nvidia-dkms-XXX  (specific version)"
            warn "    Arch:                      sudo pacman -S nvidia-dkms  (instead of nvidia-open-dkms)"
            warn "Proceeding to write the config anyway so it takes effect after the swap."
            ;;
        closed) ok "closed driver detected — GSP-off will take effect after reboot." ;;
        none)   warn "no NVIDIA driver yet — config written so it applies once the closed driver is installed." ;;
    esac
    echo ""

    log "Writing $CONF..."
    sudo tee "$CONF" > /dev/null <<'EOF'
# Disable the NVIDIA GSP firmware (GPU System Processor) bootstrap.
#
# Installed by amd-usb4-egpu-toolkit/scripts/gsp-off.sh as an opt-in
# workaround for the eGPU GSP RPC failures (Xid 79 from GSP bootstrap
# timeout, "WPR2 already up", "kgspWaitForRmInitDone" spinlock).
#
# Requires the proprietary (closed) NVIDIA kernel module. The open
# kernel module ignores this parameter and always runs with GSP on.
#
# This option is deprecated by NVIDIA and will be removed in a future
# driver release. Treat as a tactical workaround.
options nvidia NVreg_EnableGpuFirmware=0
EOF
    ok "Created $CONF"

    regen_initramfs

    echo ""
    ok "GSP-off enabled. ${B}Reboot${N} for the change to take effect."
    echo "  After reboot, verify with: cat /sys/module/nvidia/parameters/EnableGpuFirmware"
    echo "  → should print 0 if active (i.e. closed driver + this file took effect)"
}

# ---------- disable ----------
do_disable() {
    if [[ ! -f "$CONF" ]]; then
        ok "GSP-off already disabled (no $CONF)."
        exit 0
    fi
    log "Removing $CONF..."
    sudo rm "$CONF"
    ok "Removed."
    regen_initramfs
    echo ""
    ok "GSP-off disabled (reverted to NVIDIA default: GSP on). Reboot for change to take effect."
}

case "$ACTION" in
    enable)  do_enable ;;
    disable) do_disable ;;
    status)  do_status ;;
    -h|--help) sed -n '2,38p' "$0" ;;
    *) err "Unknown action: $ACTION (use: enable | disable | status)"; exit 1 ;;
esac
