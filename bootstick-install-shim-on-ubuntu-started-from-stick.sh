#!/bin/bash
set -e

echo "[*] Ubuntu USB Secure Boot Fixer (shim + grub only)"
echo

### 1. Ensure we are on Ubuntu #################################################

if ! [ -f /etc/os-release ]; then
    echo "ERROR: Cannot detect OS. /etc/os-release missing."
    exit 1
fi

. /etc/os-release

if [ "$ID" != "ubuntu" ] && [[ "$ID_LIKE" != *"ubuntu"* ]]; then
    echo "ERROR: This script must be run on Ubuntu or Ubuntu-based systems."
    echo "Detected: ID=$ID  ID_LIKE=$ID_LIKE"
    exit 1
fi

echo "[*] Running on Ubuntu: $PRETTY_NAME"
echo

### 2. Detect EFI partition mountpoint ########################################

echo "[*] Locating USB EFI System Partition by label GRUB-EFI..."

ESP_PART=$(lsblk -r -no NAME,LABEL,FSTYPE | awk '$2=="GRUB-EFI" && $3=="vfat" {print "/dev/"$1; exit}')

if [ -z "$ESP_PART" ]; then
    echo "ERROR: Could not find partition labeled GRUB-EFI."
    exit 1
fi

echo "[*] Found ESP partition: $ESP_PART"

EFI_MOUNT=/mnt/usb-esp
mkdir -p "$EFI_MOUNT"
mount "$ESP_PART" "$EFI_MOUNT"

echo "[*] Mounted ESP at: $EFI_MOUNT"

### 3. Detect the underlying block device #####################################

EFI_DISK=$(lsblk -no pkname "$ESP_PART")

if [ -z "$EFI_DISK" ]; then
    echo "ERROR: Could not determine parent disk for $ESP_PART."
    exit 1
fi

echo "[*] EFI partition is on disk: /dev/$EFI_DISK"

### 4. SAFETY CHECK: ensure disk is removable #################################

REMOVABLE=$(cat /sys/block/"$EFI_DISK"/removable)

if [ "$REMOVABLE" -ne 1 ]; then
    echo
    echo "ERROR: /dev/$EFI_DISK is NOT a removable device."
    echo "This script refuses to modify internal system EFI partitions."
    echo "Aborting."
    exit 1
fi

echo "[*] Verified: /dev/$EFI_DISK is a removable USB device."
echo

### 5. Prepare EFI/BOOT directory #############################################

BOOT_DIR="$EFI_MOUNT/EFI/BOOT"
mkdir -p "$BOOT_DIR"

echo "[*] Target directory for fallback loader: $BOOT_DIR"
echo

### 6. Locate Ubuntu signed shim + grub #######################################

SHIM_CANDIDATES=(
    "/usr/lib/shim/shimx64.efi.signed"
    "/usr/lib/shim/shimx64.efi"
)

GRUB_CANDIDATES=(
    "/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
    "/usr/lib/grub/x86_64-efi-signed/grubx64.efi"
)

MM_CANDIDATES=(
    "/usr/lib/shim/mmx64.efi.signed"
    "/usr/lib/shim/mmx64.efi"
)

find_first_existing() {
    for f in "$@"; do
        if [ -f "$f" ]; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

SHIM_SRC=$(find_first_existing "${SHIM_CANDIDATES[@]}") || {
    echo "ERROR: Could not find Ubuntu shimx64.efi (signed)."
    exit 1
}

GRUB_SRC=$(find_first_existing "${GRUB_CANDIDATES[@]}") || {
    echo "ERROR: Could not find Ubuntu grubx64.efi (signed)."
    exit 1
}

MM_SRC=$(find_first_existing "${MM_CANDIDATES[@]}" || true)

echo "[*] Using shim: $SHIM_SRC"
echo "[*] Using grub: $GRUB_SRC"
[ -n "$MM_SRC" ] && echo "[*] Using MOK manager: $MM_SRC"
echo

### 7. Install fallback loader #################################################

echo "[*] Installing Ubuntu signed shim/grub into EFI/BOOT ..."

cp "$SHIM_SRC" "$BOOT_DIR/BOOTX64.EFI"
cp "$GRUB_SRC" "$BOOT_DIR/grubx64.efi"

if [ -n "$MM_SRC" ]; then
    cp "$MM_SRC" "$BOOT_DIR/mmx64.efi"
fi

sync

echo "[*] Installation complete."
echo "[*] Contents of $BOOT_DIR:"
ls -l "$BOOT_DIR"

sync
sleep 2

umount "$EFI_MOUNT"
rm -r "$EFI_MOUNT"

echo
echo "[*] Your USB stick now uses Ubuntu's signed shim + grub."
echo "[*] It should now boot with Secure Boot enabled on strict machines (e.g., Lenovo Yoga)."
echo
