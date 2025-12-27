#!/bin/bash
set -e

echo "This script copies the grub shim. Some OS have that signed for a different location than used on removable media. Ubuntu one is ok. Maybe run this on ubuntu."

# ============================================
# CONFIGURATION
# ============================================

# USB device (NOT a partition!)
USB_DEV="/dev/sda"

EFI_SIZE="512M"

MNT_EFI="/mnt/usb-efi"
MNT_NTFS="/mnt/usb-ntfs"

if mount | grep -q "$USB_DEV"; then
    echo "ERROR: $USB_DEV is still mounted!"
    exit 1
fi

# Check if the device is removable
REMOVABLE=$(cat /sys/block/"$(basename "$USB_DEV")"/removable)

if [ "$REMOVABLE" -ne 1 ]; then
    echo "ERROR: $USB_DEV is not a removable device. Aborting."
    exit 1
fi
#
# # ============================================
# # PARTITIONING
# # ============================================
#
# echo "[*] Wiping all filesystem signatures on disk..."
# wipefs -a "$USB_DEV" || true
#
# echo "[*] Wiping partition table..."
# sgdisk --zap-all "$USB_DEV"
#
# echo "[*] Creating GPT partition table..."
# parted -s "$USB_DEV" mklabel gpt
#
# echo "[*] Creating FAT32 EFI partition..."
# parted -s "$USB_DEV" mkpart EFI fat32 1MiB "$EFI_SIZE"
# parted -s "$USB_DEV" set 1 esp on
#
# echo "[*] Creating NTFS data partition..."
# parted -s "$USB_DEV" mkpart DATA ntfs "$EFI_SIZE" 100%
#
# sleep 1
#
# # ============================================
# # FORMATTING
# # ============================================
#
# echo "[*] Formatting EFI partition as FAT32..."
# mkfs.fat -F32 -n GRUB-EFI "${USB_DEV}1"
#
# echo "[*] Formatting data partition as NTFS..."
# mkfs.ntfs -f -L GRUB-ISO-BOOT-STICK "${USB_DEV}2"

# ============================================
# MOUNTING
# ============================================

mkdir -p "$MNT_EFI" "$MNT_NTFS"

echo "[*] Mounting EFI partition..."
mount "${USB_DEV}1" "$MNT_EFI"

echo "[*] Mounting NTFS partition..."
mount "${USB_DEV}2" "$MNT_NTFS"

mkdir -p "$MNT_NTFS/iso"
mkdir -p "$MNT_EFI/boot"
touch "$MNT_EFI/boot/grub-usb-stick.mark"

# ============================================
# AUTO-DETECT SHIM + GRUB EFI FILES
# ============================================

echo "[*] Searching for shim + grub EFI binaries..."

# UNIVERSAL SEARCH FOR SHIM
SHIM=$(find /usr -type f -iname "shimx64*.efi" -o -iname "shim*.efi" 2>/dev/null | head -n 1)

# UNIVERSAL SEARCH FOR GRUB EFI
GRUBEFI=$(find /usr -type f -iname "grubx64*.efi" -o -iname "grub*.efi" 2>/dev/null | head -n 1)

# OPTIONAL: MOK manager
MMX=$(find /usr -type f -iname "mmx64.efi" 2>/dev/null | head -n 1)

if [ -z "$SHIM" ] || [ -z "$GRUBEFI" ]; then
    echo "ERROR: Could not find shim or grub EFI binaries on this system."
    echo "Install shim + grub-efi packages."
    exit 1
fi

echo "[*] Using shim: $SHIM"
echo "[*] Using grub EFI: $GRUBEFI"

mkdir -p "$MNT_EFI/EFI/BOOT"

echo "[*] Copying EFI boot files..."
cp "$SHIM" "$MNT_EFI/EFI/BOOT/BOOTX64.EFI"
cp "$GRUBEFI" "$MNT_EFI/EFI/BOOT/grubx64.efi"

if [ -n "$MMX" ]; then
    cp "$MMX" "$MNT_EFI/EFI/BOOT/mmx64.efi"
fi

# ============================================
# INSTALL GRUB MODULES (universal)
# ============================================

echo "[*] Installing GRUB modules..."

# Detect correct grub install command
if command -v grub-install >/dev/null 2>&1; then
    GRUBCMD="grub-install"
elif command -v grub2-install >/dev/null 2>&1; then
    GRUBCMD="grub2-install"
else
    echo "ERROR: Neither grub-install nor grub2-install found."
    echo "Install grub2-efi or grub-efi-amd64."
    exit 1
fi

echo "[*] Using GRUB installer: $GRUBCMD"

$GRUBCMD \
  --target=x86_64-efi \
  --efi-directory="$MNT_EFI" \
  --boot-directory="$MNT_EFI/boot" \
  --removable \
  --no-nvram

# ============================================
# INITIAL GRUB CONFIG
# ============================================

if [ -d "$MNT_EFI/boot/grub" ]; then
    GRUB_DIR="$MNT_EFI/boot/grub"
elif [ -d "$MNT_EFI/boot/grub2" ]; then
    GRUB_DIR="$MNT_EFI/boot/grub2"
else
    echo "ERROR: Neither grub nor grub2 directory exists under $MNT_EFI/boot"
    exit 1
fi

mkdir -p "$GRUB_DIR"

GRUB_CFG="$GRUB_DIR/grub.cfg"
echo "[*] Using GRUB config path: $GRUB_CFG"

echo "[*] Creating initial grub.cfg..."

cat > "$GRUB_CFG" <<EOF
set timeout=10
set default=0

menuentry "Reboot" { reboot }
menuentry "Power Off" { halt }

# ISO entries will be added by bootstick-update-iso.sh
EOF

# ============================================
# CLEANUP
# ============================================

sync
echo "[*] Unmounting..."
umount "$MNT_EFI"
umount "$MNT_NTFS"
rm -r "$MNT_EFI"
rm -r "$MNT_NTFS"

echo "[*] USB stick initialization complete."
