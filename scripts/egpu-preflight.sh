#!/bin/bash
# egpu-preflight.sh — pre-plug system readiness check
#
# Runs BEFORE you physically plug the eGPU. Verifies that:
#   1. the toolkit's configuration is properly applied
#   2. no leftover state from a previous session could cause a cascade
#   3. the kernel + userspace stack is ready to accept the plug
#
# Read-only. Never touches the driver, never starts/stops services.
# Exit codes:
#   0  → READY (with possible warnings)
#   1  → NOT READY (one or more failures)
#
# Usage:
#   ./egpu-preflight.sh           # human-readable output
#   ./egpu-preflight.sh --quiet   # only the final verdict line

set -u

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

# ANSI colors (skipped if not a TTY)
if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; BOLD=""; NC=""
fi

PASS=0
WARN=0
FAIL=0

ok()   { $QUIET || printf "  ${GREEN}✓${NC} %s\n" "$*"; PASS=$((PASS+1)); }
warn() { $QUIET || printf "  ${YELLOW}!${NC} %s\n" "$*"; WARN=$((WARN+1)); }
fail() { $QUIET || printf "  ${RED}✗${NC} %s\n" "$*"; FAIL=$((FAIL+1)); }
hdr()  { $QUIET || printf "\n${BOLD}== %s ==${NC}\n" "$*"; }

# ============================================================
hdr "Driver stack"
# ============================================================

if lsmod | grep -q '^nvidia '; then
    warn "nvidia.ko is currently loaded — eGPU might already be plugged, or stale from a previous session"
else
    ok "nvidia.ko not loaded (clean state)"
fi

if lsmod | grep -q '^nouveau '; then
    fail "nouveau is loaded — will conflict with the NVIDIA driver. Run setup-compute.sh and reboot."
else
    ok "nouveau not loaded"
fi

if command -v nvidia-smi &>/dev/null; then
    ok "nvidia-smi present (NVIDIA userspace installed)"
else
    fail "nvidia-smi missing — install nvidia-driver-cuda (see docs/install.md)"
fi

if command -v nvidia-persistenced &>/dev/null; then
    ok "nvidia-persistenced binary present"
else
    fail "nvidia-persistenced missing — install it (see docs/install.md)"
fi

# ============================================================
hdr "Toolkit configuration"
# ============================================================

if grep -q '^blacklist nouveau' /etc/modprobe.d/blacklist-nouveau.conf 2>/dev/null; then
    ok "nouveau blacklisted in modprobe.d"
else
    fail "nouveau not blacklisted — run setup-compute.sh"
fi

if grep -q '^blacklist nvidia-drm' /etc/modprobe.d/nvidia-compute-only.conf 2>/dev/null \
   && grep -q '^blacklist nvidia-modeset' /etc/modprobe.d/nvidia-compute-only.conf 2>/dev/null; then
    ok "compute-only blacklist in place (nvidia-drm + nvidia-modeset)"
else
    fail "compute-only blacklist missing or incomplete — run setup-compute.sh"
fi

if [[ -f /etc/udev/rules.d/99-nvidia-egpu-persistenced.rules ]]; then
    ok "udev rule installed"
else
    fail "udev rule missing — run setup-compute.sh"
fi

if grep -q 'ConditionPathExists=/dev/nvidia0' \
        /etc/systemd/system/nvidia-persistenced.service.d/override.conf 2>/dev/null; then
    ok "systemd drop-in in place (ConditionPathExists)"
else
    fail "systemd drop-in missing — run setup-compute.sh"
fi

if grep -q 'nvidia-drm\.modeset=0' /proc/cmdline; then
    ok "nvidia-drm.modeset=0 in kernel cmdline"
else
    warn "nvidia-drm.modeset=0 not in kernel cmdline (defense-in-depth missing)"
fi

if systemctl is-enabled nvidia-persistenced.service &>/dev/null; then
    ok "nvidia-persistenced.service enabled"
else
    fail "nvidia-persistenced.service not enabled — run: sudo systemctl enable nvidia-persistenced"
fi

# ============================================================
hdr "Clean state (no leftover from previous session)"
# ============================================================

# D-state nvidia processes = stuck spinlock waiting on a dead GPU. Reboot required.
STUCK=$(ps -eo stat,cmd 2>/dev/null | awk '/^D/ && /nvidia/ {n++} END {print n+0}')
if [[ "$STUCK" -eq 0 ]]; then
    ok "no nvidia processes in D state"
else
    fail "$STUCK nvidia process(es) stuck in D state — REBOOT before plugging (cascade risk)"
fi

if [[ -c /dev/nvidia0 ]]; then
    warn "/dev/nvidia0 exists — eGPU might already be plugged (or driver state is stale)"
else
    ok "/dev/nvidia0 does not exist (no GPU on bus)"
fi

if systemctl is-failed nvidia-persistenced.service &>/dev/null; then
    fail "nvidia-persistenced is in 'failed' state — run: sudo systemctl reset-failed nvidia-persistenced.service"
else
    ok "nvidia-persistenced not in failed state"
fi

# Drop-in working at boot: no Start-limit fail or 'Failed to query' since this boot.
PERSIST_FAILS=$(journalctl -u nvidia-persistenced.service -b 0 --no-pager 2>/dev/null \
                  | grep -cE 'Start request repeated too quickly|Failed to query NVIDIA devices' || true)
if [[ "$PERSIST_FAILS" -eq 0 ]]; then
    ok "nvidia-persistenced did not fail at boot (drop-in working as expected)"
else
    fail "nvidia-persistenced failed $PERSIST_FAILS time(s) since boot — drop-in misconfigured, reboot after fix"
fi

XID_RECENT=$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null | grep -c 'NVRM: Xid' || true)
if [[ "$XID_RECENT" -eq 0 ]]; then
    ok "no Xid events in journal (last hour)"
else
    warn "$XID_RECENT Xid event(s) in journal (last hour) — consider reboot to clear driver state"
fi

RM_RECENT=$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null \
              | grep -cE 'RmInitAdapter failed|Cannot attach gpu' || true)
if [[ "$RM_RECENT" -eq 0 ]]; then
    ok "no RmInitAdapter failures in journal (last hour)"
else
    warn "$RM_RECENT RmInitAdapter failure(s) in journal — consider reboot"
fi

NV_ON_BUS=$(lspci -d 10de: 2>/dev/null | grep -E 'VGA compatible|3D controller' | head -1)
if [[ -z "$NV_ON_BUS" ]]; then
    ok "no NVIDIA GPU currently on PCI bus (eGPU not plugged — as expected)"
else
    warn "NVIDIA GPU already on PCI bus: $NV_ON_BUS"
fi

# ============================================================
hdr "Thunderbolt / USB4"
# ============================================================

if lsmod | grep -q '^thunderbolt '; then
    ok "thunderbolt module loaded"
else
    fail "thunderbolt module not loaded — run: sudo modprobe thunderbolt"
fi

if systemctl is-active bolt.service &>/dev/null; then
    ok "bolt.service active"
else
    fail "bolt.service not active — run: sudo systemctl start bolt"
fi

if [[ -f /sys/bus/thunderbolt/devices/domain0/security ]]; then
    SEC=$(cat /sys/bus/thunderbolt/devices/domain0/security 2>/dev/null)
    ok "TB security mode: $SEC"
else
    warn "no TB domain0 in sysfs — module loaded but no host router exposed"
fi

if [[ -d /sys/class/iommu ]] && [[ -n "$(ls /sys/class/iommu 2>/dev/null)" ]]; then
    ok "IOMMU enabled (safer TB DMA)"
else
    warn "IOMMU not enabled — recommended for safe TB DMA, enable in BIOS"
fi

# ============================================================
hdr "Display path (iGPU should be driving the screen)"
# ============================================================

if lsmod | grep -q '^amdgpu '; then
    ok "amdgpu (iGPU driver) loaded"
elif lsmod | grep -q '^i915 '; then
    ok "i915 (iGPU driver) loaded — Intel host"
elif lsmod | grep -q '^xe '; then
    ok "xe (iGPU driver) loaded — Intel host, newer driver"
else
    warn "no integrated GPU driver detected — unusual setup"
fi

if ls /dev/dri/card* &>/dev/null; then
    CARDS=$(ls /dev/dri/card* | tr '\n' ' ')
    ok "DRI cards present:$CARDS"
else
    warn "no /dev/dri/cardN — display setup is unusual"
fi

# ============================================================
hdr "Kernel command line (conflicting args)"
# ============================================================

CMDLINE=$(cat /proc/cmdline)
CONFLICTS=()
echo "$CMDLINE" | grep -q 'pcie_aspm=off'      && CONFLICTS+=('pcie_aspm=off    (breaks NVIDIA driver init on TB eGPU)')
echo "$CMDLINE" | grep -q 'pcie_port_pm=off'   && CONFLICTS+=('pcie_port_pm=off (same as above)')
echo "$CMDLINE" | grep -q 'thunderbolt\.clx=0' && CONFLICTS+=('thunderbolt.clx=0 (legacy workaround; ineffective per our tests)')

if [[ ${#CONFLICTS[@]} -eq 0 ]]; then
    ok "no known conflicting kernel args"
else
    for c in "${CONFLICTS[@]}"; do
        warn "conflicting kernel arg: $c"
    done
fi

# ============================================================
# Verdict
# ============================================================

echo ""
echo "─────────────────────────────────────────────"
printf "  ${GREEN}%d ok${NC}   ${YELLOW}%d warn${NC}   ${RED}%d fail${NC}\n" "$PASS" "$WARN" "$FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    printf "${RED}${BOLD}NOT READY${NC} — fix the failures above before plugging the eGPU.\n"
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    printf "${YELLOW}${BOLD}READY WITH WARNINGS${NC} — you can plug, but review the warnings above.\n"
    printf "Procedure: Razer enclosure OFF → cable in USB4 → power ON Razer → wait ~10s → ./scripts/egpu-diag.sh\n"
    exit 0
else
    printf "${GREEN}${BOLD}READY TO PLUG${NC}\n"
    printf "Procedure: Razer enclosure OFF → cable in USB4 → power ON Razer → wait ~10s → ./scripts/egpu-diag.sh\n"
    exit 0
fi
