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
ISO_SIZE=""            # If empty, use remaining space after EFI (default behavior)
EXTRA_SIZE=""          # Optional extra partition size (MB, end of disk)
DRIVE_SIZE_MB=""
EXTRA_FS="ntfs"        # Filesystem for extra partition (default: ntfs)

KEEP_PARTITIONS=0      # Do not change partition layout or format any filesystem
WIPE_EFI_ONLY=0        # Recreate only the EFI filesystem, keep DATA and partition layout

USE_LOCAL_EFI=0
LOCAL_SHIM="shimx64.efi"
LOCAL_GRUB="grubx64.efi"
LOCAL_MMX="mmx64.efi"
FS_LABEL_BOOT="BSTICK-BOOT" #fat32, max 11 chars.
FS_LABEL_ISOS="BSTICK-ISOS" #max 16 (ext4 16, ntfs 32)
FS_LABEL_EXTRA="BSTICK-EXTRA"

MNT_EFI=""
MNT_NTFS=""

SHIM=""
GRUBEFI=""
MMX=""

USE_NTFS=0            # Default: data partition is ext4; -N switches to NTFS

# ============================================================
#  USAGE
# ============================================================

usage() {
cat <<EOF
Usage: $0 [OPTIONS]

Prepare a GRUB-based multiboot USB stick with:
  - FAT32 EFI partition (shim, grub, kernels, initrds)
  - ext4 data partition by default (ISO directories, squashfs, etc.)
    or NTFS data partition when requested via -N

Options:
  -d <device>     USB device (e.g. /dev/sda)   [REQUIRED]

  -s <size>       EFI partition size in MB, must end with 'M'
                  Typical requirement: ~200M per ISO image
                  If omitted: auto-calc = 5% of stick size but
                  min 200M and max 4000M of stick size

    -i <size>       ISO/data partition size in MB, must end with 'M'
                                    If omitted: use remaining space after the EFI partition
    -x <size>       Extra partition size in MB, must end with 'M'
                                    If provided, an extra partition will be created at the
                                    end of the disk with this size. If `-i` is omitted the
                                    script will shrink the ISO partition so the extra partition fits.
    -F <fs>         Filesystem for extra partition. Supported: ntfs, ext4
                                    Default: ntfs

  -K              KEEP_PARTITIONS:
                  Do not wipe disk or recreate partitions
                  Do not format any filesystem

  -E              WIPE_EFI_ONLY:
                  Recreate only the FAT32 EFI filesystem (partition 1)
                  Keep existing partition table and data filesystem
                  (Implies KEEP_PARTITIONS)

  -L              Load shim/grub from current directory
                  instead of auto-detecting from /usr

  -N              Format data partition as NTFS instead of ext4.
                  WARNING: NTFS may prevent ISO booting under strict
                  Secure Boot and some Linux distributions may fail
                  to boot or require additional modules when ISO or
                  squashfs files are stored on NTFS.

  -h              Show this help message

Examples:
  $0 -d /dev/sdb
  $0 -d /dev/sdc -s 2000M -L
  $0 -d /dev/sdd -E
  $0 -d /dev/sde -N

EOF
clean_exit 1
}

# ============================================================
#  ARGUMENT PARSING
# ============================================================

parse_args() {
    while getopts "d:s:i:x:F:KELNh" opt; do
        case "$opt" in
            d) USB_DEV="$OPTARG" ;;
            s) EFI_SIZE="$OPTARG" ;;
            i) ISO_SIZE="$OPTARG" ;;
            x) EXTRA_SIZE="$OPTARG" ;;
            F) EXTRA_FS="$OPTARG" ;;
            K) KEEP_PARTITIONS=1 ;;
            E) WIPE_EFI_ONLY=1; KEEP_PARTITIONS=1 ;;
            L) USE_LOCAL_EFI=1 ;;
            N) USE_NTFS=1 ;;
            h) usage ;;
            *) usage ;;
        esac
    done

    if [[ -z "$USB_DEV" ]]; then
        echo "ERROR: USB device not specified."
        usage
    fi
}

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

    # DATA
    if mountpoint -q "$MNT_NTFS"; then
        if ! umount "$MNT_NTFS"; then
            echo "WARNING: Could not unmount $MNT_NTFS — directory left intact."
        else
            echo "[*] Unmounted $MNT_NTFS"
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
# after cleanup_mounts is defined since it is called
parse_args "$@"

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

validate_iso_size() {
    if [[ ! "$ISO_SIZE" =~ ^[0-9]+M$ ]]; then
        echo "ERROR: ISO/data size must end with 'M' (megabytes)."
        echo "Example: -i 1024M"
        clean_exit 1
    fi
}

validate_extra_size() {
    if [[ ! "$EXTRA_SIZE" =~ ^[0-9]+M$ ]]; then
        echo "ERROR: Extra partition size must end with 'M' (megabytes)."
        echo "Example: -x 2048M"
        clean_exit 1
    fi
}

validate_extra_fs() {
    local fs=$(echo "$EXTRA_FS" | tr '[:upper:]' '[:lower:]')
    if [[ "$fs" != "ntfs" && "$fs" != "ext4" ]]; then
        echo "ERROR: Unsupported extra partition filesystem: $EXTRA_FS"
        echo "Supported: ntfs, ext4"
        clean_exit 1
    fi
    EXTRA_FS="$fs"
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
    DRIVE_SIZE_MB=$size_mb

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


read_drive_size_mb() {
    local dev
    dev=$(basename "$USB_DEV" | sed -E 's/p?[0-9]+$//')
    if [[ -z "$dev" ]]; then
        echo "ERROR: Cannot determine device base name for $USB_DEV"
        clean_exit 1
    fi
    if [[ ! -r "/sys/block/$dev/size" ]]; then
        echo "ERROR: Cannot read /sys/block/$dev/size to determine drive size." 
        clean_exit 1
    fi
    local sectors
    sectors=$(cat "/sys/block/$dev/size")
    DRIVE_SIZE_MB=$(( sectors / 2048 ))
}


check_partition_sizes() {
    read_drive_size_mb

    local efi_mb=${EFI_SIZE%M}

    if [[ -n "$EXTRA_SIZE" && -z "$ISO_SIZE" ]]; then
        # If extra provided and ISO omitted, shrink ISO to fit
        local extra_mb=${EXTRA_SIZE%M}
        local iso_mb=$(( DRIVE_SIZE_MB - efi_mb - extra_mb ))
        if (( iso_mb <= 0 )); then
            echo "ERROR: Not enough space on device for EFI (${efi_mb}M) + extra (${extra_mb}M)."
            echo "Drive total: ${DRIVE_SIZE_MB}M"
            clean_exit 1
        fi
        ISO_SIZE="${iso_mb}M"
        echo "[*] Calculated ISO/Data size to ${ISO_SIZE} so extra partition fits."
        validate_iso_size
    fi

    if [[ -n "$ISO_SIZE" ]]; then
        validate_iso_size
    fi
    if [[ -n "$EXTRA_SIZE" ]]; then
        validate_extra_size
    fi

    # Now verify sums don't exceed drive size
    local iso_mb_final=0
    if [[ -n "$ISO_SIZE" ]]; then
        iso_mb_final=${ISO_SIZE%M}
    fi
    local extra_mb_final=0
    if [[ -n "$EXTRA_SIZE" ]]; then
        extra_mb_final=${EXTRA_SIZE%M}
    fi

    local sum=$(( efi_mb + iso_mb_final + extra_mb_final ))
    if (( sum > DRIVE_SIZE_MB )); then
        echo "ERROR: Requested partition sizes exceed drive size (${sum}M > ${DRIVE_SIZE_MB}M)."
        echo "EFI: ${efi_mb}M ISO: ${iso_mb_final}M EXTRA: ${extra_mb_final}M"
        clean_exit 1
    fi
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

    echo "[*] Creating data partition (ext4 by default)..."
    # If EXTRA_SIZE set, we expect check_partition_sizes() to have computed
    # ISO_SIZE (if omitted) and ensured the sums fit the drive.
    if [[ -n "$ISO_SIZE" ]]; then
        local efi_mb=${EFI_SIZE%M}
        local iso_mb=${ISO_SIZE%M}
        local iso_end_mb=$(( efi_mb + iso_mb ))
        parted -s "$USB_DEV" mkpart DATA ext4 "$EFI_SIZE" "${iso_end_mb}MiB"
    else
        parted -s "$USB_DEV" mkpart DATA ext4 "$EFI_SIZE" 100%
    fi

    # Create optional extra partition at the end
    if [[ -n "$EXTRA_SIZE" ]]; then
        local iso_end_mb=${EFI_SIZE%M}
        if [[ -n "$ISO_SIZE" ]]; then
            iso_end_mb=$(( ${EFI_SIZE%M} + ${ISO_SIZE%M} ))
        else
            # If ISO_SIZE was calculated by check_partition_sizes it will be set
            iso_end_mb=$(( ${EFI_SIZE%M} + ${ISO_SIZE%M} ))
        fi
        local extra_end_mb=$(( iso_end_mb + ${EXTRA_SIZE%M} ))
        parted -s "$USB_DEV" mkpart EXTRA ext4 "${iso_end_mb}MiB" "${extra_end_mb}MiB"
    fi

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
    mkfs.fat -F32 -n "$FS_LABEL_BOOT" "${USB_DEV}1"

    # Now decide whether to format data partition
    if [[ "$WIPE_EFI_ONLY" -eq 1 ]]; then
        echo "[*] WIPE_EFI_ONLY enabled — data partition left untouched."
        return
    fi

    if [[ "$USE_NTFS" -eq 1 ]]; then
        echo "[*] Formatting data partition (${USB_DEV}2) as NTFS..."
        echo "    WARNING: NTFS may break ISO booting under strict Secure Boot."
        echo "    Some Linux distributions may not boot correctly when ISO or"
        echo "    squashfs files reside on NTFS, or may require additional modules."
        mkfs.ntfs -f -L "$FS_LABEL_ISOS" "${USB_DEV}2"
    else
        echo "[*] Formatting data partition (${USB_DEV}2) as ext4..."
        mkfs.ext4 -F -L "$FS_LABEL_ISOS" "${USB_DEV}2"
    fi

    # Format extra partition if requested (partition 3)
    if [[ -n "$EXTRA_SIZE" ]]; then
        if [[ "$EXTRA_FS" == "ntfs" ]]; then
            echo "[*] Formatting extra partition (${USB_DEV}3) as NTFS..."
            mkfs.ntfs -f -L "$FS_LABEL_EXTRA" "${USB_DEV}3"
        else
            echo "[*] Formatting extra partition (${USB_DEV}3) as ext4..."
            mkfs.ext4 -F -L "$FS_LABEL_EXTRA" "${USB_DEV}3"
        fi
    fi
}


# ============================================================
#  MOUNTING
# ============================================================

mount_partitions() {
    echo "[*] Mounting EFI partition ${USB_DEV}1 at $MNT_EFI..."
    mount "${USB_DEV}1" "$MNT_EFI"

    echo "[*] Mounting data partition ${USB_DEV}2 at $MNT_NTFS..."
    if ! mount "${USB_DEV}2" "$MNT_NTFS"; then
        echo "WARNING: Could not mount ${USB_DEV}2 — continuing without data partition."
    else
        mkdir -p "$MNT_NTFS/iso"
    fi

    mkdir -p "$MNT_EFI/boot/grub-bstick"
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
        --boot-directory="$MNT_EFI/boot/grub-bstick" \
        --removable \
        --no-nvram
}

# ============================================================
#  GRUB CONFIG
# ============================================================

write_grub_cfg() {
    local grub_dir

    if [[ -d "$MNT_EFI/boot/grub-bstick/grub" ]]; then
        grub_dir="$MNT_EFI/boot/grub-bstick/grub"
    elif [[ -d "$MNT_EFI/boot/grub-bstick/grub2" ]]; then
        grub_dir="$MNT_EFI/boot/grub-bstick/grub2"
    else
        echo "ERROR: Neither grub nor grub2 directory exists under $MNT_EFI/boot/grub-bstick"
        clean_exit 1
    fi

    mkdir -p "$grub_dir"

    local cfg="$grub_dir/grub.cfg"
    echo "[*] Writing initial GRUB config to $cfg"

    cat > "$cfg" <<EOF
set timeout=300
set default=0

menuentry "Power Off" { halt }
menuentry "Reboot" { reboot }

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
    if [[ -n "$ISO_SIZE" ]]; then
        validate_iso_size
    fi
    if [[ -n "$EXTRA_SIZE" ]]; then
        validate_extra_size
    fi

    # Determine drive size and ensure requested partitions fit
    check_partition_sizes
    make_mount_dirs

    echo "============================================================"
    echo " Bootstick Initialization Parameters"
    echo "============================================================"
    echo " USB Device:          $USB_DEV"
    echo " EFI Size:            $EFI_SIZE"
    if [[ -n "$ISO_SIZE" ]]; then
        echo " ISO/Data Size:       $ISO_SIZE"
    else
        echo " ISO/Data Size:       <use remaining space>"
    fi
    if [[ -n "$EXTRA_SIZE" ]]; then
        echo " Extra Partition Size: $EXTRA_SIZE"
    else
        echo " Extra Partition Size: <none>"
    fi
    echo " KEEP_PARTITIONS:     $KEEP_PARTITIONS"
    echo " WIPE_EFI_ONLY:       $WIPE_EFI_ONLY"
    echo " USE_LOCAL_EFI:       $USE_LOCAL_EFI"
    if [[ "$USE_NTFS" -eq 1 ]]; then
        echo " DATA filesystem:     NTFS"
    else
        echo " DATA filesystem:     ext4"
    fi
    echo " EFI mount dir:       $MNT_EFI"
    echo " DATA mount dir:      $MNT_NTFS"
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
