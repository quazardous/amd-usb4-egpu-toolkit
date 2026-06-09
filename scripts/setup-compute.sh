#!/bin/bash
# setup-compute.sh — distro-agnostic config for NVIDIA eGPU compute-only mode
#
# What it does (idempotent, asks before touching anything important):
#   1. /etc/modprobe.d/blacklist-nouveau.conf  — keep nouveau off the eGPU
#   2. /etc/modprobe.d/nvidia-compute-only.conf — skip nvidia-drm/modeset so
#      GNOME/mutter does not enumerate the eGPU as a display device (avoids the
#      compositor freeze pattern on AMD Phoenix + USB4)
#   3. Install udev/99-nvidia-egpu-persistenced.rules
#   4. Install systemd/nvidia-persistenced.service.d/override.conf
#   5. systemd daemon-reload + udevadm reload
#   6. Regenerate initramfs (auto-detected: dracut / update-initramfs / mkinitcpio)
#   7. Print kernel-cmdline guidance for your bootloader (manual final step)
#
# What it does NOT do:
#   - install nvidia-driver / nvidia-driver-cuda — distro-specific
#     (dnf / apt / pacman). See README per-distro instructions.
#   - install nvidia-persistenced package — same reason. See README.
#   - touch your bootloader configuration directly — printed instead.
#
# Usage:
#   ./setup-compute.sh           # interactive (asks before sudo writes)
#   ./setup-compute.sh --yes     # non-interactive (CI / scripted)
#   ./setup-compute.sh --uninstall

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ASSUME_YES=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=true; shift ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

confirm() {
    $ASSUME_YES && return 0
    local prompt="${1:-Continue?} [y/N] "
    read -rp "$prompt" reply
    [[ "$reply" =~ ^[yY]$ ]]
}

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[✓] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err()  { printf '[✗] %s\n' "$*" >&2; }

write_root_file() {
    local src="$1" dst="$2"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
        ok "$dst already up to date"
        return 0
    fi
    log "Writing $dst (from $(realpath --relative-to="$REPO_DIR" "$src"))"
    confirm "  Apply?" || { warn "Skipped $dst"; return 0; }
    sudo install -m 0644 "$src" "$dst"
    ok "Installed $dst"
}

write_inline() {
    # write_inline DEST <<< 'content'
    local dst="$1"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        ok "$dst already up to date"
        rm -f "$tmp"
        return 0
    fi
    log "Writing $dst"
    confirm "  Apply?" || { warn "Skipped $dst"; rm -f "$tmp"; return 0; }
    sudo install -m 0644 "$tmp" "$dst"
    rm -f "$tmp"
    ok "Installed $dst"
}

remove_if_present() {
    local p="$1"
    if [[ -e "$p" ]]; then
        log "Removing $p"
        confirm "  Confirm?" || { warn "Skipped $p"; return 0; }
        sudo rm -f "$p"
        ok "Removed $p"
    fi
}

# ---------- initramfs detection ----------
regen_initramfs() {
    if command -v dracut &>/dev/null; then
        log "Regenerating initramfs (dracut -f)..."
        sudo dracut -f
        ok "initramfs regenerated (dracut)"
    elif command -v update-initramfs &>/dev/null; then
        log "Regenerating initramfs (update-initramfs -u)..."
        sudo update-initramfs -u
        ok "initramfs regenerated (update-initramfs)"
    elif command -v mkinitcpio &>/dev/null; then
        log "Regenerating initramfs (mkinitcpio -P)..."
        sudo mkinitcpio -P
        ok "initramfs regenerated (mkinitcpio)"
    else
        warn "Unknown initramfs tool. Regenerate manually before reboot."
    fi
}

# ---------- bootloader cmdline guidance ----------
print_cmdline_guidance() {
    cat <<'EOF'

================================================================================
MANUAL STEP — kernel command line
================================================================================

For compute-only mode, add this to the kernel command line:

    nvidia-drm.modeset=0

This is defense-in-depth: even if nvidia-drm somehow loads, modeset=0 prevents
it from grabbing display modesetting. Skip it if you intend to switch to
display mode later (i.e. plug a monitor into the eGPU).

How to add it depends on your bootloader:

  Fedora / RHEL / openSUSE (grubby):
      sudo grubby --update-kernel=ALL --args="nvidia-drm.modeset=0"

  Debian / Ubuntu (GRUB):
      Edit /etc/default/grub
      Append " nvidia-drm.modeset=0" to GRUB_CMDLINE_LINUX_DEFAULT
      sudo update-grub

  Arch / Manjaro (GRUB):
      Edit /etc/default/grub
      Append " nvidia-drm.modeset=0" to GRUB_CMDLINE_LINUX_DEFAULT
      sudo grub-mkconfig -o /boot/grub/grub.cfg

  systemd-boot:
      Edit /boot/loader/entries/*.conf
      Append " nvidia-drm.modeset=0" to the "options" line

Reboot after applying.
================================================================================
EOF
}

# ---------- install ----------
do_install() {
    log "Installing AMD/USB4 eGPU compute-only configuration"
    echo ""

    write_inline /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
# Keep nouveau out of the eGPU's way. The proprietary/open nvidia driver
# blacklists nouveau via its own modprobe.d, but on a hot-plug scenario nouveau
# can still load transiently from initramfs and grab the GPU before nvidia.ko
# binds, leading to half-init state + IRQ-thread deadlock on hot-unplug.
blacklist nouveau
options nouveau modeset=0
EOF

    write_inline /etc/modprobe.d/nvidia-compute-only.conf <<'EOF'
# Compute-only: do not load the DRM/modeset pieces of the nvidia driver.
# Without nvidia-drm.ko, no /dev/dri/cardN is created for the eGPU, so
# GNOME/mutter never tries to enumerate it as a render device. nvidia.ko +
# nvidia-uvm.ko are sufficient for CUDA (Ollama, llama.cpp, ComfyUI, PyTorch).
#
# Remove this file if you want to use the eGPU for display.
blacklist nvidia-drm
blacklist nvidia-modeset
EOF

    write_root_file "$REPO_DIR/udev/99-nvidia-egpu-persistenced.rules" \
                    /etc/udev/rules.d/99-nvidia-egpu-persistenced.rules

    sudo install -d -m 0755 /etc/systemd/system/nvidia-persistenced.service.d
    write_root_file "$REPO_DIR/systemd/nvidia-persistenced.service.d/override.conf" \
                    /etc/systemd/system/nvidia-persistenced.service.d/override.conf

    # Shutdown helper: cleanly stops persistenced + unloads nvidia.ko before
    # systemd starts tearing down the TB stack. Avoids the "shutdown spinner
    # hangs" pattern observed when nvidia.ko has refs at module-unload time.
    sudo install -d -m 0755 /usr/local/lib/amd-usb4-egpu-toolkit
    write_root_file "$REPO_DIR/scripts/shutdown-helper.sh" \
                    /usr/local/lib/amd-usb4-egpu-toolkit/shutdown-helper.sh
    sudo chmod +x /usr/local/lib/amd-usb4-egpu-toolkit/shutdown-helper.sh
    write_root_file "$REPO_DIR/systemd/nvidia-egpu-shutdown.service" \
                    /etc/systemd/system/nvidia-egpu-shutdown.service

    log "Reloading systemd + udev rules..."
    sudo systemctl daemon-reload
    sudo udevadm control --reload
    ok "systemd + udev reloaded"

    # Enable the shutdown hook so its ExecStop runs on every poweroff/reboot.
    if ! systemctl is-enabled nvidia-egpu-shutdown.service &>/dev/null; then
        log "Enabling nvidia-egpu-shutdown.service..."
        if confirm "  Enable nvidia-egpu-shutdown.service?"; then
            sudo systemctl enable nvidia-egpu-shutdown.service
            ok "nvidia-egpu-shutdown.service enabled"
        else
            warn "Skipped — enable manually with: sudo systemctl enable nvidia-egpu-shutdown.service"
        fi
    else
        ok "nvidia-egpu-shutdown.service already enabled"
    fi

    regen_initramfs

    print_cmdline_guidance

    echo ""
    ok "Setup complete."
    echo "Next steps:"
    echo "  1. install nvidia-driver-cuda + cuda-toolkit + nvidia-persistenced (see README per-distro)"
    echo "  2. add the kernel cmdline arg above and reboot"
    echo "  3. plug eGPU (cable first, then power on the enclosure)"
    echo "  4. ./scripts/egpu-diag.sh  →  verdict should be OK-Gen4x4 (or OK-Gen3x4 on TB3)"
}

# ---------- uninstall ----------
do_uninstall() {
    log "Removing AMD/USB4 eGPU compute-only configuration"
    # Disable the shutdown hook first so removal of its files doesn't leave a
    # dangling enable-symlink.
    if systemctl is-enabled nvidia-egpu-shutdown.service &>/dev/null; then
        log "Disabling nvidia-egpu-shutdown.service..."
        sudo systemctl disable nvidia-egpu-shutdown.service
    fi
    remove_if_present /etc/systemd/system/nvidia-egpu-shutdown.service
    remove_if_present /usr/local/lib/amd-usb4-egpu-toolkit/shutdown-helper.sh
    sudo rmdir /usr/local/lib/amd-usb4-egpu-toolkit 2>/dev/null || true
    remove_if_present /etc/modprobe.d/blacklist-nouveau.conf
    remove_if_present /etc/modprobe.d/nvidia-compute-only.conf
    remove_if_present /etc/udev/rules.d/99-nvidia-egpu-persistenced.rules
    remove_if_present /etc/systemd/system/nvidia-persistenced.service.d/override.conf

    log "Reloading systemd + udev..."
    sudo systemctl daemon-reload
    sudo udevadm control --reload
    ok "Reloaded"

    regen_initramfs
    warn "Don't forget to remove 'nvidia-drm.modeset=0' from your kernel command line if you added it."
}

if $UNINSTALL; then
    do_uninstall
else
    do_install
fi
