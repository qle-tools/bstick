#!/bin/bash
set -e

# ============================================
# CONFIGURATION
# ============================================

USB_DEV="/dev/sdb"

MNT_EFI="/mnt/usb-efi"
MNT_NTFS="/mnt/usb-ntfs"

ISO_DIR="$MNT_NTFS/iso"

# ============================================
# MOUNT PARTITIONS
# ============================================

mkdir -p "$MNT_EFI" "$MNT_NTFS"

echo "[*] Mounting EFI partition..."
mount "${USB_DEV}1" "$MNT_EFI" || true

echo "[*] Mounting NTFS partition..."
mount "${USB_DEV}2" "$MNT_NTFS" || true

# ============================================
# WRITE BASE GRUB CONFIG
# ============================================

# Detect GRUB directory on EFI partition
if [ -d "$MNT_EFI/boot/grub" ]; then
    GRUB_DIR="$MNT_EFI/boot/grub"
elif [ -d "$MNT_EFI/boot/grub2" ]; then
    GRUB_DIR="$MNT_EFI/boot/grub2"
else
    echo "ERROR: Neither grub nor grub2 directory exists under $MNT_EFI/boot"
    exit 1
fi

GRUB_CFG="$GRUB_DIR/grub.cfg"
echo "[*] Using GRUB config path: $GRUB_CFG"

echo "[*] Writing base grub.cfg..."

cat > "$GRUB_CFG" <<EOF
set timeout=10
set default=0

menuentry "Reboot" { reboot }
menuentry "Power Off" { halt }

EOF

# ============================================
# ADD ISO ENTRIES
# ============================================

echo "[*] Scanning for ISO files..."

detect_distro() {
    local filename="$1"
    case "$filename" in
        *ubuntu*|*debian*|*kali*)
            echo "debian-family"
            ;;
        *fedora*|*centos*|*rhel*)
            echo "redhat-family"
            ;;
        *opensuse*|*Leap*|*Slowroll*)
            echo "opensuse"
            ;;
        *arch*)
            echo "arch"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

get_kernel_initrd() {
    local distro="$1"
    case "$distro" in
        debian-family)
            echo "/casper/vmlinuz|/casper/initrd"
            ;;
        redhat-family)
            echo "/isolinux/vmlinuz|/isolinux/initrd.img"
            ;;
        opensuse)
            echo "/boot/x86_64/loader/linux|/boot/x86_64/loader/initrd"
            ;;
        arch)
            echo "/arch/boot/x86_64/vmlinuz|/arch/boot/x86_64/archiso.img"
            ;;
        *)
            echo "|"
            ;;
    esac
}

get_kernel_params() {
    local distro="$1"
    case "$distro" in
        debian-family)
            echo "boot=casper iso-scan/filename=\$isofile quiet splash ---"
            ;;
        redhat-family)
            echo "inst.stage2=hd:LABEL=GRUB-ISO-BOOT-STICK:\$isofile quiet"
            ;;
        opensuse)
            echo "install=hd:LABEL=GRUB-ISO-BOOT-STICK:\$isofile"
            ;;
        arch)
            echo "archiso loop=\$isofile"
            ;;
        *)
            echo ""
            ;;
    esac
}

add_grub_entry() {
    local filename="$1"
    local name="${filename%.*}"
    local distro="$2"
    local kernel="$3"
    local initrd="$4"
    local params="$5"

    cat >> "$GRUB_CFG" <<EOF
menuentry "$name (ISO boot)" {
    search --file --set=root /boot/grub-usb-stick.mark
    regexp --set=1:disk '^([^,]*).*$' \$root
    set ntfsdev="(\$disk,gpt2)"
    set isofile="/iso/$filename"
    loopback loop \$ntfsdev\$isofile
    linux (loop)$kernel $params
    initrd (loop)$initrd
}
EOF
}

for iso in "$ISO_DIR"/*.iso; do
    [ -e "$iso" ] || continue
    filename=$(basename "$iso")
    echo "[*] Adding ISO: $filename"

    distro=$(detect_distro "$filename")
    ki=$(get_kernel_initrd "$distro")
    kernel=$(echo "$ki" | cut -d'|' -f1)
    initrd=$(echo "$ki" | cut -d'|' -f2)
    params=$(get_kernel_params "$distro")

    if [ -n "$kernel" ] && [ -n "$initrd" ]; then
        add_grub_entry "$filename" "$distro" "$kernel" "$initrd" "$params"
    else
        echo "WARNING: No kernel/initrd mapping for $filename"
    fi
done



sync

# ============================================
# CLEANUP
# ============================================

sync
echo "[*] Unmounting..."
umount "$MNT_EFI"
umount "$MNT_NTFS"
rm -r "$MNT_EFI"
rm -r "$MNT_NTFS"

echo "[*] ISO update complete."
