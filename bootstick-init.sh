#!/bin/bash
set -euo pipefail
# set -x # see full detail if you  have trouble


# Initialize tracking variables
current_command=""
last_command=""

# Track last command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG

# Log unexpected exit
trap 'rc=$?; if [[ $rc -ne 0 ]]; then
    echo "ERROR: command \"$last_command\" exited with status $rc" >&2
    cleanup_mounts
fi' EXIT

# Exit trap would trigger no normal exits. So call this instead.
clean_exit() {
    local code="${1:-0}"
    trap - EXIT
    trap - DEBUG
    cleanup_mounts
    exit "$code"
}




# ============================================================
#  GLOBAL DEFAULTS
# ============================================================

USB_DEV=""
EFI_SIZE=""            # If empty, auto-calculated based on stick size

KEEP_PARTITIONS=0      # Do not change partition layout or format any filesystem
WIPE_EFI_ONLY=0        # Recreate only the EFI filesystem, keep NTFS and partition layout

USE_LOCAL_EFI=0
LOCAL_SHIM="shimx64.efi"
LOCAL_GRUB="grubx64.efi"
LOCAL_MMX="mmx64.efi"

MNT_EFI=""
MNT_NTFS=""

SHIM=""
GRUBEFI=""
MMX=""

# ============================================================
#  USAGE
# ============================================================

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

Prepare a GRUB-based multiboot USB stick with:
  - FAT32 EFI partition (shim, grub, kernels, initrds)
  - NTFS data partition (ISO directories, squashfs, etc.)

Options:
  -d <device>     USB device (e.g. /dev/sda)   [REQUIRED]

  -s <size>       EFI partition size in MB, must end with 'M'
                  Typical requirement: ~200M per ISO image
                  If omitted: auto-calc = 5% of stick size but
                  min 200M and max 4000M of stick size

  -K              KEEP_PARTITIONS:
                  Do not wipe disk or recreate partitions
                  Do not format any filesystem

  -E              WIPE_EFI_ONLY:
                  Recreate only the FAT32 EFI filesystem (partition 1)
                  Keep existing partition table and NTFS filesystem
                  (Implies KEEP_PARTITIONS)

  -L              Load shim/grub from current directory
                  instead of auto-detecting from /usr

  -h              Show this help message

Examples:
  $0 -d /dev/sdb
  $0 -d /dev/sdc -s 2000M -L
  $0 -d /dev/sdd -E

EOF
clean_exit 1
}

# ============================================================
#  ARGUMENT PARSING
# ============================================================

parse_args() {
    while getopts "d:s:KELh" opt; do
        case "$opt" in
            d) USB_DEV="$OPTARG" ;;
            s) EFI_SIZE="$OPTARG" ;;
            K) KEEP_PARTITIONS=1 ;;
            E) WIPE_EFI_ONLY=1; KEEP_PARTITIONS=1 ;;
            L) USE_LOCAL_EFI=1 ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    if [[ -z "$USB_DEV" ]]; then
        echo "ERROR: USB device not specified."
        usage
    fi
}

parse_args "$@"

# ============================================================
#  RANDOM MOUNT DIRS
# ============================================================

make_mount_dirs() {
    local r=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)

    MNT_EFI="/tmp/bootstick-grub-efi-mount-$r"
    MNT_NTFS="/tmp/bootstick-grub-iso-ntfs-mount-$r"

    mkdir -p "$MNT_EFI" "$MNT_NTFS"
}

cleanup_mounts() {
    sync || true

    # EFI
    if mountpoint -q "$MNT_EFI"; then
        if ! umount "$MNT_EFI"; then
            echo "WARNING: Could not unmount $MNT_EFI — directory left intact."
        else
            echo "[*] Unmounted $MNT_EFI"
        fi
    fi

    # NTFS
    if mountpoint -q "$MNT_NTFS"; then
        if ! umount "$MNT_NTFS"; then
            echo "WARNING: Could not unmount $MNT_NTFS — directory left intact."
        else
            echo "[*] Unmounted $MNT_EFI"
        fi
    fi

    # Remove mount dirs only if empty
    if [[ -d "$MNT_EFI" ]]; then
        if rmdir "$MNT_EFI" 2>/dev/null; then
            true
        else
            echo "WARNING: $MNT_EFI not empty — not removed."
        fi
    fi

    if [[ -d "$MNT_NTFS" ]]; then
        if rmdir "$MNT_NTFS" 2>/dev/null; then
            true
        else
            echo "WARNING: $MNT_NTFS not empty — not removed."
        fi
    fi
}


## trap cleanup_mounts EXIT

# ============================================================
#  VALIDATION
# ============================================================

validate_device() {
    local mounts_left
    if mount | grep -q "^$USB_DEV"; then
        mount | grep "^$USB_DEV"
        echo "ERROR: $USB_DEV is still mounted. See above."
        clean_exit 1
    fi

    local removable=$(cat "/sys/block/$(basename "$USB_DEV")/removable")

    if [[ "$removable" -ne 1 ]]; then
        echo "ERROR: $USB_DEV is not a removable device."
        clean_exit 1
    fi
}

validate_efi_size() {
    if [[ ! "$EFI_SIZE" =~ ^[0-9]+M$ ]]; then
        echo "ERROR: EFI size must end with 'M' (megabytes)."
        echo "Example: -s 512M"
        echo "Rule of thumb: ~200M per ISO image."
        clean_exit 1
    fi
}

# ============================================================
#  EFI SIZE AUTO-CALC
# ============================================================

calc_default_efi_size() {
    # Strip partition suffix (handles sda1, mmcblk0p1, nvme0n1p1)
    local dev
    dev=$(basename "$USB_DEV" | sed -E 's/p?[0-9]+$//')


    # Read number of 512-byte sectors
    local sectors
    sectors=$(cat "/sys/block/$dev/size")

    # Convert to MiB (2048 sectors = 1 MiB)
    local size_mb
    size_mb=$(( sectors / 2048 ))

    # Compute 5%
    local five_percent
    five_percent=$(( size_mb * 5 / 100 ))

    local efi=$five_percent
    if (( efi < 200 )); then
        efi=200
    fi
    if (( efi > 4000 )); then
        efi=4000
    fi

    EFI_SIZE="${efi}M"
}

# ============================================================
#  PARTITIONING
# ============================================================

partition_disk() {
    if [[ "$KEEP_PARTITIONS" -eq 1 ]]; then
        echo "[*] KEEP_PARTITIONS enabled — skipping partitioning."
        return
    fi

    echo "[*] Wiping filesystem signatures on $USB_DEV..."
    wipefs -a "$USB_DEV" || true

    echo "[*] Wiping partition table..."
    sgdisk --zap-all "$USB_DEV"

    echo "[*] Creating GPT partition table..."
    parted -s "$USB_DEV" mklabel gpt

    echo "[*] Creating FAT32 EFI partition..."
    parted -s "$USB_DEV" mkpart EFI fat32 1MiB "$EFI_SIZE"
    parted -s "$USB_DEV" set 1 esp on

    echo "[*] Creating NTFS data partition..."
    parted -s "$USB_DEV" mkpart DATA ntfs "$EFI_SIZE" 100%

    sleep 1
}

# ============================================================
#  FORMATTING
# ============================================================

format_partitions() {

    # Case 1: KEEP_PARTITIONS → do nothing at all
    if [[ "$KEEP_PARTITIONS" -eq 1 && "$WIPE_EFI_ONLY" -eq 0 ]]; then
        echo "[*] KEEP_PARTITIONS enabled — skipping all formatting."
        return
    fi

    # Case 2 and 3: We always format EFI unless KEEP_PARTITIONS prevented it
    echo "[*] Formatting EFI partition (${USB_DEV}1) as FAT32..."
    mkfs.fat -F32 -n GRUB-EFI "${USB_DEV}1"

    # Now decide whether to format NTFS
    if [[ "$WIPE_EFI_ONLY" -eq 1 ]]; then
        echo "[*] WIPE_EFI_ONLY enabled — NTFS left untouched."
    else
        echo "[*] Formatting NTFS partition (${USB_DEV}2) as NTFS..."
        mkfs.ntfs -f -L GRUB-ISO-BOOT-STICK "${USB_DEV}2"
    fi
}


# ============================================================
#  MOUNTING
# ============================================================

mount_partitions() {
    echo "[*] Mounting EFI partition ${USB_DEV}1 at $MNT_EFI..."
    mount "${USB_DEV}1" "$MNT_EFI"

    echo "[*] Mounting NTFS partition ${USB_DEV}2 at $MNT_NTFS..."
    if ! mount "${USB_DEV}2" "$MNT_NTFS"; then
        echo "WARNING: Could not mount ${USB_DEV}2 — continuing without NTFS."
    else
        mkdir -p "$MNT_NTFS/iso"
    fi

    mkdir -p "$MNT_EFI/boot"
    touch "$MNT_EFI/boot/grub-usb-stick.mark"
}

# ============================================================
#  EFI FILES
# ============================================================

find_efi_files() {
    if [[ "$USE_LOCAL_EFI" -eq 1 ]]; then
        SHIM="$LOCAL_SHIM"
        GRUBEFI="$LOCAL_GRUB"
        MMX="$LOCAL_MMX"

        [[ -f "$SHIM" ]] || { echo "ERROR: Missing $SHIM"; clean_exit 1; } || true
        [[ -f "$GRUBEFI" ]] || { echo "ERROR: Missing $GRUBEFI"; clean_exit 1; } || true

        echo "[*] Using local EFI binaries from current directory."
        echo "[*] SHIM: $SHIM"
        echo "[*] GRUB EFI: $GRUBEFI"
        [[ -f "$MMX" ]] && echo "[*] MOK manager: $MMX" || true

        return
    fi

    echo "[*] Auto-detecting shim + grub EFI binaries..."

    SHIM=$(find /usr -type f \( -iname "shimx64*.efi" -o -iname "shim*.efi" \) 2>/dev/null | head -n 1 || true)
    GRUBEFI=$(find /usr -type f \( -iname "grubx64*.efi" -o -iname "grub*.efi" \) 2>/dev/null | head -n 1 || true)
    MMX=$(find /usr -type f -iname "mmx64.efi" 2>/dev/null | head -n 1 || true)

    if [[ -z "$SHIM" || -z "$GRUBEFI" ]]; then
        echo "ERROR: Could not find shim or grub EFI binaries."
        echo "Install shim + grub-efi packages or use -L with local files."
        clean_exit 1
    fi

    echo "[*] Using shim: $SHIM"
    echo "[*] Using grub EFI: $GRUBEFI"
    [[ -n "$MMX" ]] && echo "[*] Using MOK manager: $MMX" || true
}

copy_efi_files() {
    echo "[*] Copying EFI boot files to $MNT_EFI/EFI/BOOT..."

    mkdir -p "$MNT_EFI/EFI/BOOT"

    cp "$SHIM"    "$MNT_EFI/EFI/BOOT/BOOTX64.EFI"
    cp "$GRUBEFI" "$MNT_EFI/EFI/BOOT/grubx64.efi"

    if [[ -n "$MMX" && -f "$MMX" ]]; then
        cp "$MMX" "$MNT_EFI/EFI/BOOT/mmx64.efi"
    fi
}

# ============================================================
#  GRUB INSTALL
# ============================================================

install_grub() {
    echo "[*] Installing GRUB modules..."

    local GRUBCMD=""

    if command -v grub-install >/dev/null 2>&1; then
        GRUBCMD="grub-install"
    elif command -v grub2-install >/dev/null 2>&1; then
        GRUBCMD="grub2-install"
    else
        echo "ERROR: Neither grub-install nor grub2-install found."
        echo "Install grub2-efi or grub-efi-amd64."
        clean_exit 1
    fi

    echo "[*] Using GRUB installer: $GRUBCMD"

    $GRUBCMD \
        --target=x86_64-efi \
        --efi-directory="$MNT_EFI" \
        --boot-directory="$MNT_EFI/boot" \
        --removable \
        --no-nvram
}

# ============================================================
#  GRUB CONFIG
# ============================================================

write_grub_cfg() {
    local grub_dir

    if [[ -d "$MNT_EFI/boot/grub" ]]; then
        grub_dir="$MNT_EFI/boot/grub"
    elif [[ -d "$MNT_EFI/boot/grub2" ]]; then
        grub_dir="$MNT_EFI/boot/grub2"
    else
        echo "ERROR: Neither grub nor grub2 directory exists under $MNT_EFI/boot"
        clean_exit 1
    fi

    mkdir -p "$grub_dir"

    local cfg="$grub_dir/grub.cfg"
    echo "[*] Writing initial GRUB config to $cfg"

    cat > "$cfg" <<EOF
set timeout=60
set default=0

menuentry "Reboot" { reboot }
menuentry "Power Off" { halt }

# ISO entries will be added by bootstick-update-iso.sh
EOF
}

# ============================================================
#  MAIN
# ============================================================

main() {
    validate_device

    if [[ -z "$EFI_SIZE" ]]; then
        echo "[*] No EFI size provided — calculating default..."
        calc_default_efi_size
    fi

    validate_efi_size
    make_mount_dirs

    echo "============================================================"
    echo " Bootstick Initialization Parameters"
    echo "============================================================"
    echo " USB Device:          $USB_DEV"
    echo " EFI Size:            $EFI_SIZE"
    echo " KEEP_PARTITIONS:     $KEEP_PARTITIONS"
    echo " WIPE_EFI_ONLY:       $WIPE_EFI_ONLY"
    echo " USE_LOCAL_EFI:       $USE_LOCAL_EFI"
    echo " EFI mount dir:       $MNT_EFI"
    echo " NTFS mount dir:      $MNT_NTFS"
    echo "============================================================"

    partition_disk
    format_partitions
    mount_partitions
    find_efi_files
    copy_efi_files
    install_grub
    write_grub_cfg

    cleanup_mounts

    echo "[*] USB stick initialization complete."

    # Final status: is the stick still mounted anywhere?
    if mount | grep -q "^$USB_DEV"; then
        echo
        mount | grep "^$USB_DEV"
        echo
        echo "============================================================"
        echo " Finished, but the USB stick is still mounted somewhere."
        echo " See mount locations above."
        echo " Please eject it safely using your operating system."
        echo "============================================================"
    else
        echo
        echo "============================================================"
        echo " Finished successfully. The USB stick is unmounted and"
        echo " can now be safely removed."
        echo "============================================================"
    fi

}

main

# We have an exit handler we want to turn off on normal exit
clean_exit 0
