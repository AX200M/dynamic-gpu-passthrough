#!/bin/bash
# =============================================================================
# VFIO GPU Passthrough Setup Script
# =============================================================================
# Automates dynamic GPU passthrough setup for Linux systems with:
#   - An iGPU (for the host desktop)
#   - A discrete GPU (for VM passthrough, reclaimable by host)
#
# Tested on: Fedora 44, GNOME, AMD Ryzen + RX 9070 XT
# Should work on: Any systemd-based distro with KVM/QEMU support
#
# GitHub: https://github.com/ax200m/dynamic-gpu-passthrough
# License: MIT
# =============================================================================

set -euo pipefail

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Colour

# --- Helpers -----------------------------------------------------------------
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }
ask()     { echo -e "${YELLOW}[INPUT]${NC} $*"; }

# --- Root check --------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root."
    echo "  Run: sudo bash $0"
    exit 1
fi

# --- Intro -------------------------------------------------------------------
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
 __   _____ ___ ___     ___  ___ _   _
 \ \ / / __|_ _/ _ \   / __|/ __| | | |
  \ V /| _| | | (_) |  \__ \ (_ | |_| |
   \_/ |_| |___\___/   |___/\___|\___/

  Dynamic GPU Passthrough Setup Script
  Discrete GPU → VM passthrough + host reclaim
EOF
echo -e "${NC}"
echo -e "This script will:"
echo -e "  ${GREEN}✓${NC} Verify IOMMU is enabled"
echo -e "  ${GREEN}✓${NC} Detect your discrete GPU"
echo -e "  ${GREEN}✓${NC} Load and persist VFIO kernel modules"
echo -e "  ${GREEN}✓${NC} Install vfio-bind.sh and vfio-release.sh"
echo -e "  ${GREEN}✓${NC} Set up libvirt hooks for automatic GPU switching"
echo -e "  ${GREEN}✓${NC} Optionally install virtualisation packages\n"
warn "This script modifies kernel modules and system files."
warn "A backup of any modified files will be created automatically."
echo ""
read -rp "Press ENTER to continue or Ctrl+C to abort..."

# =============================================================================
# STEP 1 — Detect distro
# =============================================================================
header "Step 1: Detecting Distribution"

if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-unknown}"
    info "Detected: $DISTRO_NAME"
else
    warn "Could not detect distro. Assuming systemd-based with dnf or apt."
    DISTRO_ID="unknown"
fi

# Package manager detection
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
elif command -v pacman &>/dev/null; then
    PKG_MGR="pacman"
else
    PKG_MGR="unknown"
    warn "Could not detect package manager. Skipping package installation."
fi

info "Package manager: ${PKG_MGR}"

# =============================================================================
# STEP 2 — Check IOMMU
# =============================================================================
header "Step 2: Checking IOMMU"

IOMMU_ACTIVE=false
if dmesg | grep -q -e "AMD-Vi" -e "DMAR" -e "IOMMU"; then
    success "IOMMU appears active in dmesg."
    IOMMU_ACTIVE=true
else
    warn "IOMMU not detected in dmesg."
fi

# Check kernel cmdline
CMDLINE=$(cat /proc/cmdline)
if echo "$CMDLINE" | grep -q "iommu=pt\|amd_iommu=on\|intel_iommu=on"; then
    success "IOMMU kernel parameters found in /proc/cmdline."
    IOMMU_ACTIVE=true
else
    warn "IOMMU kernel parameters not found in /proc/cmdline."
    echo ""
    echo -e "  You need to add IOMMU parameters to your bootloader."
    echo -e "  ${BOLD}For AMD CPUs:${NC}  amd_iommu=on iommu=pt"
    echo -e "  ${BOLD}For Intel CPUs:${NC} intel_iommu=on iommu=pt"
    echo ""

    if [ -f /etc/default/grub ]; then
        warn "Attempting to add IOMMU parameters to GRUB automatically..."
        echo ""

        # Detect CPU vendor
        CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
        if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
            IOMMU_PARAMS="amd_iommu=on iommu=pt"
        else
            IOMMU_PARAMS="intel_iommu=on iommu=pt"
        fi

        ask "Add \"${IOMMU_PARAMS}\" to GRUB? (y/N)"
        read -rp "> " ADD_IOMMU
        if [[ "${ADD_IOMMU,,}" == "y" ]]; then
            cp /etc/default/grub /etc/default/grub.bak
            info "Backup saved to /etc/default/grub.bak"
            sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"${IOMMU_PARAMS} /" /etc/default/grub
            if command -v grub2-mkconfig &>/dev/null; then
                grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
                grub2-mkconfig -o /boot/efi/EFI/${DISTRO_ID}/grub.cfg 2>/dev/null || \
                warn "Could not auto-update GRUB config. Run grub2-mkconfig manually."
            elif command -v update-grub &>/dev/null; then
                update-grub
            fi
            success "GRUB updated. A reboot is required before continuing."
            echo ""
            warn "Please reboot and re-run this script."
            exit 0
        else
            error "IOMMU is required for GPU passthrough. Aborting."
            exit 1
        fi
    else
        error "Cannot auto-configure IOMMU. Please enable it manually and re-run."
        exit 1
    fi
fi

# =============================================================================
# STEP 3 — Detect GPU
# =============================================================================
header "Step 3: Detecting GPUs"

info "Scanning PCI devices for GPUs..."
echo ""

# List all VGA/3D/Display controllers
mapfile -t GPU_LIST < <(lspci -nn | grep -E "VGA|3D|Display" || true)

if [ ${#GPU_LIST[@]} -eq 0 ]; then
    error "No GPUs detected. Cannot continue."
    exit 1
fi

echo -e "  ${BOLD}Detected GPUs:${NC}"
for i in "${!GPU_LIST[@]}"; do
    echo -e "  ${CYAN}[$i]${NC} ${GPU_LIST[$i]}"
done
echo ""

if [ ${#GPU_LIST[@]} -eq 1 ]; then
    warn "Only one GPU detected. You need both an iGPU and a dGPU for dynamic passthrough."
    warn "Proceeding anyway — static passthrough may still be possible."
fi

ask "Which GPU do you want to pass through to the VM? (enter number)"
read -rp "> " GPU_CHOICE

if ! [[ "$GPU_CHOICE" =~ ^[0-9]+$ ]] || [ "$GPU_CHOICE" -ge "${#GPU_LIST[@]}" ]; then
    error "Invalid selection."
    exit 1
fi

SELECTED_GPU="${GPU_LIST[$GPU_CHOICE]}"
GPU_PCI_SHORT=$(echo "$SELECTED_GPU" | awk '{print $1}')
GPU_PCI="0000:${GPU_PCI_SHORT}"
GPU_IDS=$(echo "$SELECTED_GPU" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1)
GPU_VENDOR=$(echo "$GPU_IDS" | cut -d: -f1)
GPU_DEVICE=$(echo "$GPU_IDS" | cut -d: -f2)

success "Selected GPU: $SELECTED_GPU"
info "PCI address: $GPU_PCI"
info "PCI ID: ${GPU_VENDOR}:${GPU_DEVICE}"

# Detect associated audio device (typically .1 of the same slot)
GPU_PCI_BASE=$(echo "$GPU_PCI_SHORT" | sed 's/\.[0-9]$//')
AUDIO_LINE=$(lspci -nn | grep "${GPU_PCI_BASE}\." | grep -i "audio\|sound\|hda" || true)

if [ -n "$AUDIO_LINE" ]; then
    GPU_AUDIO_SHORT=$(echo "$AUDIO_LINE" | awk '{print $1}')
    GPU_AUDIO="0000:${GPU_AUDIO_SHORT}"
    AUDIO_IDS=$(echo "$AUDIO_LINE" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1)
    success "Detected GPU audio device: $AUDIO_LINE"
    info "Audio PCI address: $GPU_AUDIO"
else
    warn "No audio device found for this GPU slot."
    ask "Enter audio PCI address manually (e.g. 0000:03:00.1) or press ENTER to skip:"
    read -rp "> " GPU_AUDIO
    GPU_AUDIO="${GPU_AUDIO:-none}"
fi

echo ""

# IOMMU group check
info "Checking IOMMU group for ${GPU_PCI}..."
IOMMU_GROUP_PATH=$(find /sys/kernel/iommu_groups/*/devices/ -name "${GPU_PCI}" 2>/dev/null | head -1 || true)
if [ -n "$IOMMU_GROUP_PATH" ]; then
    IOMMU_GROUP=$(echo "$IOMMU_GROUP_PATH" | grep -oP 'iommu_groups/\K[0-9]+')
    info "GPU is in IOMMU group: $IOMMU_GROUP"
    echo ""
    echo -e "  ${BOLD}All devices in this IOMMU group:${NC}"
    for dev in /sys/kernel/iommu_groups/${IOMMU_GROUP}/devices/*; do
        lspci -nns "$(basename "$dev")" 2>/dev/null || true
    done
    echo ""
    GROUP_DEVICE_COUNT=$(ls /sys/kernel/iommu_groups/${IOMMU_GROUP}/devices/ | wc -l)
    if [ "$GROUP_DEVICE_COUNT" -gt 2 ]; then
        warn "More than 2 devices share this IOMMU group."
        warn "You may need to pass through all of them, or apply the ACS override patch."
    else
        success "IOMMU group looks clean."
    fi
else
    warn "Could not determine IOMMU group. IOMMU may not be fully active."
fi

# =============================================================================
# STEP 4 — Detect current GPU driver
# =============================================================================
header "Step 4: Detecting Current GPU Driver"

CURRENT_DRIVER=$(lspci -nnk -s "$GPU_PCI_SHORT" | grep "Kernel driver in use" | awk '{print $NF}' || true)
if [ -n "$CURRENT_DRIVER" ]; then
    info "GPU is currently using driver: ${BOLD}$CURRENT_DRIVER${NC}"
else
    warn "Could not detect current driver for GPU."
    CURRENT_DRIVER="unknown"
fi

# =============================================================================
# STEP 5 — Load and persist VFIO modules
# =============================================================================
header "Step 5: Loading VFIO Kernel Modules"

MODULES=("vfio" "vfio_iommu_type1" "vfio_pci")

for mod in "${MODULES[@]}"; do
    if lsmod | grep -q "$mod"; then
        success "Module already loaded: $mod"
    else
        info "Loading module: $mod"
        modprobe "$mod" && success "Loaded: $mod" || error "Failed to load: $mod"
    fi
done

# Persist modules
MODULES_CONF="/etc/modules-load.d/vfio.conf"
if [ ! -f "$MODULES_CONF" ]; then
    info "Writing $MODULES_CONF..."
    cat > "$MODULES_CONF" << EOF
vfio
vfio_iommu_type1
vfio_pci
EOF
    success "Module persistence configured."
else
    success "$MODULES_CONF already exists, skipping."
fi

# softdep to load vfio-pci before the GPU driver
MODPROBE_CONF="/etc/modprobe.d/vfio.conf"
if [ ! -f "$MODPROBE_CONF" ]; then
    info "Writing $MODPROBE_CONF (softdep: vfio-pci before ${CURRENT_DRIVER})..."
    cat > "$MODPROBE_CONF" << EOF
softdep ${CURRENT_DRIVER} pre: vfio-pci
EOF
    success "modprobe softdep configured."
else
    success "$MODPROBE_CONF already exists, skipping."
fi

# =============================================================================
# STEP 6 — Write vfio-bind.sh
# =============================================================================
header "Step 6: Writing vfio-bind.sh"

BIND_SCRIPT="/usr/local/bin/vfio-bind.sh"

cat > "$BIND_SCRIPT" << SCRIPT
#!/bin/bash
set -euo pipefail

GPU_PCI="${GPU_PCI}"
GPU_AUDIO="${GPU_AUDIO}"
HOST_DRIVER="${CURRENT_DRIVER}"

if [[ \$EUID -ne 0 ]]; then
    echo "ERROR: Must be run as root" >&2
    exit 1
fi

# Already bound to vfio-pci — nothing to do
if [ -e /sys/bus/pci/drivers/vfio-pci/\$GPU_PCI ]; then
    echo "[vfio-bind] GPU already bound to vfio-pci, nothing to do."
    exit 0
fi

echo "[vfio-bind] Unbinding GPU from \${HOST_DRIVER}..."
if [ -e /sys/bus/pci/drivers/\${HOST_DRIVER}/\$GPU_PCI ]; then
    echo "\$GPU_PCI" > /sys/bus/pci/drivers/\${HOST_DRIVER}/unbind
else
    echo "[vfio-bind] WARN: GPU not bound to \${HOST_DRIVER}, skipping"
fi

if [ "\$GPU_AUDIO" != "none" ]; then
    echo "[vfio-bind] Unbinding GPU audio..."
    for audio_driver in snd_hda_intel vfio-pci; do
        if [ -e /sys/bus/pci/drivers/\${audio_driver}/\$GPU_AUDIO ]; then
            echo "\$GPU_AUDIO" > /sys/bus/pci/drivers/\${audio_driver}/unbind
            break
        fi
    done
fi

echo "[vfio-bind] Binding GPU to vfio-pci..."
echo "vfio-pci" > /sys/bus/pci/devices/\$GPU_PCI/driver_override
echo "\$GPU_PCI" > /sys/bus/pci/drivers/vfio-pci/bind

if [ "\$GPU_AUDIO" != "none" ]; then
    echo "[vfio-bind] Binding GPU audio to vfio-pci..."
    echo "vfio-pci" > /sys/bus/pci/devices/\$GPU_AUDIO/driver_override
    echo "\$GPU_AUDIO" > /sys/bus/pci/drivers/vfio-pci/bind
fi

echo "[vfio-bind] Done. GPU is ready for passthrough."
SCRIPT

chmod +x "$BIND_SCRIPT"
success "Written: $BIND_SCRIPT"

# =============================================================================
# STEP 7 — Write vfio-release.sh
# =============================================================================
header "Step 7: Writing vfio-release.sh"

RELEASE_SCRIPT="/usr/local/bin/vfio-release.sh"

cat > "$RELEASE_SCRIPT" << SCRIPT
#!/bin/bash
set -euo pipefail

GPU_PCI="${GPU_PCI}"
GPU_AUDIO="${GPU_AUDIO}"
HOST_DRIVER="${CURRENT_DRIVER}"

if [[ \$EUID -ne 0 ]]; then
    echo "ERROR: Must be run as root" >&2
    exit 1
fi

# Already bound to host driver — nothing to do
if [ -e /sys/bus/pci/drivers/\${HOST_DRIVER}/\$GPU_PCI ]; then
    echo "[vfio-release] GPU already bound to \${HOST_DRIVER}, nothing to do."
    exit 0
fi

echo "[vfio-release] Unbinding GPU from vfio-pci..."
if [ -e /sys/bus/pci/drivers/vfio-pci/\$GPU_PCI ]; then
    echo "\$GPU_PCI" > /sys/bus/pci/drivers/vfio-pci/unbind
else
    echo "[vfio-release] WARN: GPU not bound to vfio-pci, skipping"
fi

if [ "\$GPU_AUDIO" != "none" ]; then
    echo "[vfio-release] Unbinding GPU audio from vfio-pci..."
    if [ -e /sys/bus/pci/drivers/vfio-pci/\$GPU_AUDIO ]; then
        echo "\$GPU_AUDIO" > /sys/bus/pci/drivers/vfio-pci/unbind
    else
        echo "[vfio-release] WARN: Audio not bound to vfio-pci, skipping"
    fi
fi

echo "[vfio-release] Clearing driver_override..."
echo "" > /sys/bus/pci/devices/\$GPU_PCI/driver_override
[ "\$GPU_AUDIO" != "none" ] && echo "" > /sys/bus/pci/devices/\$GPU_AUDIO/driver_override

echo "[vfio-release] Rescanning PCI bus..."
echo 1 > /sys/bus/pci/devices/\$GPU_PCI/remove
[ "\$GPU_AUDIO" != "none" ] && echo 1 > /sys/bus/pci/devices/\$GPU_AUDIO/remove
echo 1 > /sys/bus/pci/rescan

echo "[vfio-release] Done. GPU returned to host."
SCRIPT

chmod +x "$RELEASE_SCRIPT"
success "Written: $RELEASE_SCRIPT"

# =============================================================================
# STEP 8 — Libvirt hooks
# =============================================================================
header "Step 8: Setting Up Libvirt Hooks"

# List VMs if libvirt is available
VM_NAME=""
if command -v virsh &>/dev/null; then
    echo -e "  ${BOLD}Available VMs:${NC}"
    virsh list --all 2>/dev/null || true
    echo ""
    ask "Enter the exact name of your Windows VM (from the list above):"
    read -rp "> " VM_NAME
else
    warn "virsh not found. Skipping VM detection."
    ask "Enter your VM name manually (you can edit the hooks later):"
    read -rp "> " VM_NAME
fi

VM_NAME="${VM_NAME:-windows}"

HOOK_DIR="/etc/libvirt/hooks"
PREPARE_DIR="${HOOK_DIR}/qemu.d/${VM_NAME}/prepare/begin"
RELEASE_DIR="${HOOK_DIR}/qemu.d/${VM_NAME}/release/end"

mkdir -p "$PREPARE_DIR"
mkdir -p "$RELEASE_DIR"

# Main dispatcher
cat > "${HOOK_DIR}/qemu" << 'HOOK'
#!/bin/bash
#
# Libvirt QEMU hook dispatcher
# Automatically calls per-VM scripts on lifecycle events
#
GUEST_NAME="$1"
OPERATION="$2"
SUB_OPERATION="$3"

HOOK_DIR="/etc/libvirt/hooks/qemu.d"
SCRIPT="${HOOK_DIR}/${GUEST_NAME}/${OPERATION}/${SUB_OPERATION}/run.sh"

if [ -f "$SCRIPT" ]; then
    exec "$SCRIPT" "$@"
fi
HOOK
chmod +x "${HOOK_DIR}/qemu"
success "Written: ${HOOK_DIR}/qemu"

# Prepare hook
cat > "${PREPARE_DIR}/run.sh" << HOOK
#!/bin/bash
set -euo pipefail
exec >> /var/log/vfio-hook.log 2>&1
echo "--- \$(date) | prepare/begin fired for ${VM_NAME} ---"
sleep 2
exec /usr/local/bin/vfio-bind.sh
HOOK
chmod +x "${PREPARE_DIR}/run.sh"
success "Written: ${PREPARE_DIR}/run.sh"

# Release hook
cat > "${RELEASE_DIR}/run.sh" << HOOK
#!/bin/bash
set -euo pipefail
exec >> /var/log/vfio-hook.log 2>&1
echo "--- \$(date) | release/end fired for ${VM_NAME} ---"
exec /usr/local/bin/vfio-release.sh
HOOK
chmod +x "${RELEASE_DIR}/run.sh"
success "Written: ${RELEASE_DIR}/run.sh"

# =============================================================================
# STEP 9 — Optionally install virtualisation packages
# =============================================================================
header "Step 9: Virtualisation Packages"

ask "Install KVM/QEMU/virt-manager packages? (y/N)"
read -rp "> " INSTALL_VIRT

if [[ "${INSTALL_VIRT,,}" == "y" ]]; then
    case "$PKG_MGR" in
        dnf)
            dnf install -y @virtualization virt-manager qemu-kvm libvirt virt-viewer
            ;;
        apt-get)
            apt-get install -y qemu-kvm libvirt-daemon-system virt-manager virtinst
            ;;
        pacman)
            pacman -S --noconfirm qemu virt-manager libvirt dnsmasq
            ;;
        *)
            warn "Unknown package manager. Install qemu-kvm, libvirt, and virt-manager manually."
            ;;
    esac
    systemctl enable --now libvirtd
    success "Virtualisation packages installed and libvirtd enabled."
else
    info "Skipping package installation."
fi

# =============================================================================
# STEP 10 — Restart libvirtd
# =============================================================================
header "Step 10: Restarting libvirtd"

if systemctl is-active --quiet libvirtd; then
    systemctl restart libvirtd
    success "libvirtd restarted."
else
    warn "libvirtd is not running. Start it with: sudo systemctl start libvirtd"
fi

# =============================================================================
# Summary
# =============================================================================
header "Setup Complete"

echo -e "  ${BOLD}GPU:${NC}          $SELECTED_GPU"
echo -e "  ${BOLD}GPU PCI:${NC}      $GPU_PCI"
echo -e "  ${BOLD}Audio PCI:${NC}    $GPU_AUDIO"
echo -e "  ${BOLD}Host driver:${NC}  $CURRENT_DRIVER"
echo -e "  ${BOLD}VM name:${NC}      $VM_NAME"
echo ""
echo -e "  ${BOLD}Files written:${NC}"
echo -e "    /usr/local/bin/vfio-bind.sh"
echo -e "    /usr/local/bin/vfio-release.sh"
echo -e "    /etc/libvirt/hooks/qemu"
echo -e "    /etc/libvirt/hooks/qemu.d/${VM_NAME}/prepare/begin/run.sh"
echo -e "    /etc/libvirt/hooks/qemu.d/${VM_NAME}/release/end/run.sh"
echo -e "    /etc/modules-load.d/vfio.conf"
echo -e "    /etc/modprobe.d/vfio.conf"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  ${CYAN}1.${NC} Add the GPU to your VM's XML:"
echo -e "     sudo virsh edit ${VM_NAME}"
echo -e "  ${CYAN}2.${NC} Test bind/release manually:"
echo -e "     sudo /usr/local/bin/vfio-bind.sh"
echo -e "     sudo /usr/local/bin/vfio-release.sh"
echo -e "  ${CYAN}3.${NC} Monitor hook logs when starting your VM:"
echo -e "     tail -f /var/log/vfio-hook.log"
echo -e "  ${CYAN}4.${NC} Consider Looking Glass for display output:"
echo -e "     https://looking-glass.io"
echo ""
success "All done. Happy passthrough!"
