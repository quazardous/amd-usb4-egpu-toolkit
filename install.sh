#!/bin/bash
# install.sh — one-shot install: NVIDIA eGPU as a CUDA-only accelerator on an
# AMD USB4 laptop.
#
# Fedora (RPM Fusion) is automated end to end. Other distros: follow
# docs/install.md for the driver, then run scripts/setup-compute.sh.
#
# What it does (Fedora):
#   1. enables RPM Fusion (free + nonfree) if missing
#   2. forces the CLOSED nvidia module (RPM Fusion builds the open one for
#      Turing+ by default, and the open one cannot turn the GSP off)
#   3. installs akmod-nvidia + xorg-x11-drv-nvidia-cuda (libcuda, nvidia-smi,
#      nvidia-persistenced)
#   4. builds and installs the module for every installed kernel, and checks
#      it is the closed one
#   5. applies the compute-only config (scripts/setup-compute.sh)
#   6. turns the GSP firmware off (scripts/gsp-off.sh)
#   7. adds nvidia-drm.modeset=0, enables nvidia-persistenced, disables
#      nvidia-powerd, hides the nvidia-settings login autostart
#   8. optionally installs cuda-toolkit + cmake (for scripts/egpu-stress.sh)
#
# Usage:
#   ./install.sh                     # interactive
#   ./install.sh --yes               # no questions
#   ./install.sh --with-cuda-toolkit # also nvcc + cmake (stress tests)
#   ./install.sh --keep-gsp          # leave the GSP on (open module allowed)
#
# Run as your normal user (it calls sudo itself), with the eGPU UNPLUGGED.
# Reboot afterwards. Details and rationale: docs/install.md.

set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# One language for the whole output: dnf, akmods and systemctl otherwise
# follow the system locale and mix with this script's English messages.
# Inherited by the sub-scripts; sudo keeps LC_* (Fedora's default env_keep).
export LC_ALL=C.UTF-8

ASSUME_YES=false
WITH_CUDA=false
KEEP_GSP=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)            ASSUME_YES=true; shift ;;
        --with-cuda-toolkit) WITH_CUDA=true; shift ;;
        --keep-gsp)          KEEP_GSP=true; shift ;;
        -h|--help)           sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1 (see --help)" >&2; exit 1 ;;
    esac
done

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[✗] %s\n' "$*" >&2; exit 1; }
confirm() {
    $ASSUME_YES && return 0
    local reply; read -rp "${1:-Continue?} [y/N] " reply
    [[ "$reply" =~ ^[yY]$ ]]
}

CLOSED_MACRO=/etc/rpm/macros.nvidia-kmod-closed

# ---------- preconditions ----------
[[ $EUID -ne 0 ]] || die "Run as your normal user, not root (sudo is called when needed)."
# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != fedora ]]; then
    warn "Automated install is Fedora-only for now (detected: ${PRETTY_NAME:-unknown})."
    warn "Install the driver per docs/install.md, then run: $REPO_DIR/scripts/setup-compute.sh"
    exit 1
fi

if lspci -d 10de: 2>/dev/null | grep -qE 'VGA|3D'; then
    warn "An NVIDIA GPU is on the bus. Install with the eGPU UNPLUGGED (power off, cable out)."
    confirm "Continue anyway?" || exit 1
fi

log "Fedora ${VERSION_ID}, kernel $(uname -r)"
log "Plan: closed NVIDIA driver (RPM Fusion)$($KEEP_GSP || echo ', GSP off'), compute-only$($WITH_CUDA && echo ', cuda-toolkit')"
confirm "Proceed?" || exit 1

# ---------- 1. RPM Fusion ----------
if [[ -z "$(dnf repoquery -q akmod-nvidia 2>/dev/null)" ]]; then
    log "Enabling RPM Fusion (free + nonfree)..."
    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
fi

# ---------- 2. closed module ----------
if $KEEP_GSP; then
    [[ -f "$CLOSED_MACRO" ]] && sudo rm -f "$CLOSED_MACRO"
else
    # akmod-nvidia ships both flavours and picks one at build time: its
    # nvidia-kmod-noopen-checks script selects open for every Turing+ GPU.
    # This macro skips the detection and keeps the closed kernel/ tree.
    printf '%s\n' '# Written by amd-usb4-egpu-toolkit install.sh: build the CLOSED nvidia module.' \
        '%_without_kmod_nvidia_detect 1' | sudo tee "$CLOSED_MACRO" >/dev/null
    ok "Closed module forced ($CLOSED_MACRO)"
fi

# Driver packages from NVIDIA's CUDA repo conflict with RPM Fusion's.
old=$(rpm -qa --qf '%{NAME}\t%{VENDOR}\n' | awk -F'\t' \
    '$2 ~ /NVIDIA/ && $1 ~ /^(nvidia-|kmod-nvidia|dkms-nvidia|libnvidia|xorg-x11-nvidia)/ {print $1}' | tr '\n' ' ')
if [[ -n "${old// }" ]]; then
    log "Removing NVIDIA CUDA-repo driver packages: $old"
    # shellcheck disable=SC2086
    sudo dnf remove -y $old
fi
if rpm -q akmod-nvidia-open &>/dev/null && ! $KEEP_GSP; then
    sudo dnf swap -y akmod-nvidia-open akmod-nvidia
fi

# ---------- 3. packages ----------
log "Installing akmod-nvidia + xorg-x11-drv-nvidia-cuda..."
sudo dnf install -y "kernel-devel-$(uname -r)" akmod-nvidia xorg-x11-drv-nvidia-cuda

# ---------- 4. build for every kernel ----------
# --rebuild: an existing (open) kmod is otherwise judged up to date.
# Install the built RPM ourselves: akmods can print "Successful" while dnf
# answered "available but not installed", and a rebuilt kmod has the same
# version as one already installed.
akmod_ver=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' akmod-nvidia)
bad=()
while read -r k; do
    [[ -n "$k" ]] || continue
    rpm -q "kernel-devel-$k" &>/dev/null || sudo dnf install -y "kernel-devel-$k" \
        || { warn "kernel-devel-$k unavailable, skipping $k"; continue; }
    log "Building the nvidia module for $k (a few minutes)..."
    sudo akmods --force --rebuild --akmod nvidia --kernels "$k" || warn "akmods reported an error for $k"
    rpmf="/var/cache/akmods/nvidia/kmod-nvidia-${k}-${akmod_ver}.rpm"
    if [[ -f "$rpmf" ]]; then
        if rpm -q "kmod-nvidia-$k" &>/dev/null; then sudo dnf reinstall -y "$rpmf"
        else sudo dnf install -y "$rpmf"; fi
    fi
    ko=$(find "/lib/modules/$k/extra" -name 'nvidia.ko*' 2>/dev/null | head -1)
    lic=$([[ -n "$ko" ]] && modinfo -F license "$ko" 2>/dev/null || true)
    case "$lic" in
        NVIDIA)      ok "$k: closed module" ;;
        *MIT*|*GPL*) $KEEP_GSP && ok "$k: open module" || { warn "$k: OPEN module built"; bad+=("$k"); } ;;
        *)           warn "$k: no module found"; bad+=("$k") ;;
    esac
done < <(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n')
[[ ${#bad[@]} -eq 0 ]] || die "No closed module for: ${bad[*]} — see /var/cache/akmods/nvidia/*.log"

# ---------- 5-6. toolkit config ----------
bash "$REPO_DIR/scripts/setup-compute.sh" --yes
if $KEEP_GSP; then
    [[ -f /etc/modprobe.d/nvidia-gsp-off.conf ]] && bash "$REPO_DIR/scripts/gsp-off.sh" disable
else
    bash "$REPO_DIR/scripts/gsp-off.sh" enable
fi

# ---------- 7. kernel arg, services, autostart ----------
if ! sudo grubby --info=DEFAULT | grep -q 'nvidia-drm.modeset=0'; then
    sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=0"
    ok "nvidia-drm.modeset=0 added to the kernel command line"
fi
sudo systemctl enable nvidia-persistenced.service   # udev starts it on plug
if systemctl is-enabled nvidia-powerd.service &>/dev/null; then
    sudo systemctl disable --now nvidia-powerd.service  # crashes on TB/USB4 eGPUs
fi
# nvidia-settings is a hard dependency and GNOME autostarts it at login,
# where it fails without the eGPU. Hide it for this user.
mkdir -p "$HOME/.config/autostart"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=NVIDIA X Server Settings' \
    '# Written by amd-usb4-egpu-toolkit install.sh' 'Hidden=true' \
    > "$HOME/.config/autostart/nvidia-settings-user.desktop"

# ---------- 8. optional CUDA toolkit ----------
if $WITH_CUDA; then
    repo="cuda-fedora$(rpm -E %fedora)-x86_64"
    if ! dnf repolist --all 2>/dev/null | grep -q "^$repo"; then
        sudo dnf config-manager addrepo --from-repofile="https://developer.download.nvidia.com/compute/cuda/repos/fedora$(rpm -E %fedora)/x86_64/cuda-fedora$(rpm -E %fedora).repo"
    fi
    # The driver comes from RPM Fusion: keep NVIDIA's repo from providing one.
    sudo dnf config-manager setopt "$repo.excludepkgs=nvidia-*,kmod-nvidia*,dkms-nvidia*,libnvidia*,xorg-x11-nvidia*"
    sudo dnf install -y cuda-toolkit cmake
    ok "cuda-toolkit installed (add /usr/local/cuda/bin to PATH)"
fi

echo ""
ok "Install complete."
echo "Next:"
echo "  1. reboot with the eGPU UNPLUGGED"
echo "  2. $REPO_DIR/scripts/egpu-preflight.sh   → READY TO PLUG"
echo "  3. enclosure off → plug the cable → enclosure on → wait ~10 s"
echo "  4. $REPO_DIR/scripts/egpu-diag.sh        → OK-Gen4x4, then nvidia-smi"
