#!/bin/bash
set -euo pipefail

# Initialize tracking variables
current_command=""
last_command=""

# Track last command
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG

# Log unexpected exit
trap 'rc=$?; if [[ $rc -ne 0 ]]; then
    echo "ERROR: command \"$last_command\" exited with status $rc" >&2
fi' EXIT

# ============================================================
# CONFIGURATION
# ============================================================

USB_DEV="/dev/sda"
NTFS_LABEL="BSTICK-BOOT" #fat32, max 11 chars.

MNT_EFI="/mnt/usb-efi"
MNT_NTFS="/mnt/usb-ntfs"

ISO_DIR="$MNT_NTFS/iso"

# temp file for loopback.cfg handling
LOOPBACK_TMP=""

# ============================================================
# MOUNT PARTITIONS
# ============================================================

mkdir -p "$MNT_EFI" "$MNT_NTFS"
mount "${USB_DEV}1" "$MNT_EFI" || true
mount "${USB_DEV}2" "$MNT_NTFS" || true

# ============================================================
# DETECT GRUB DIRECTORY
# ============================================================

if [ -d "$MNT_EFI/boot/grub-bstick/grub" ]; then
    GRUB_DIR_NAME="grub"
elif [ -d "$MNT_EFI/boot/grub-bstick/grub2" ]; then
    GRUB_DIR_NAME="grub2"
else
    echo "ERROR: No grub directory found at MNT_EFI/boot/grub-bstick"
    exit 1
fi

GRUB_DIR="$MNT_EFI/boot/grub-bstick/$GRUB_DIR_NAME"

GRUB_CFG="$GRUB_DIR/grub.cfg"

# ============================================================
# BASE GRUB CONFIG
# ============================================================

cat > "$GRUB_CFG" <<EOF
set timeout=300
set default=0

menuentry "Power Off" { halt }
menuentry "Reboot" { reboot }
EOF


# ============================================================
# ISO FAMILY DETECTION
# ============================================================

detect_family() {
    local name="$1"
    shopt -s nocasematch
    case "$name" in
        *win7*|*windows7*) echo "windows7" ;;
        *win8*|*windows8*|*win81*) echo "windows8" ;;
        *win10*|*windows10*) echo "windows10" ;;
        *win11*|*windows11*) echo "windows11" ;;
        *windows*) echo "windows" ;;   # Windows To Go also matches here
        *ubuntu*|*mint*|*zorin*|*pop-os*) echo "ubuntu" ;;
        *debian*|*kali*|*parrot*) echo "debian" ;;
        *fedora*|*centos*|*rhel*|*rocky*|*alma*) echo "redhat" ;;
        *opensuse*|*suse*|*leap*|*tumbleweed*) echo "opensuse" ;;
        *arch*|*manjaro*|*endeavouros*) echo "arch" ;;
        *) echo "unknown" ;;
    esac
    shopt -u nocasematch
}

# ============================================================
# AUTO-DETECT KERNEL + INITRD (LINUX)
# ============================================================

find_kernel_initrd() {
    local path="$1"
    kernel_src=""
    initrd_src=""

    echo "[*] Searching for initrd in: $path"

    # Search for initrd files across the entire directory structure first
    initrd_src=$(find "$path" -type f \( -iname "initrd*" -o -iname "initramfs*" -o -iname "archiso*.img" -o -iname "*live*.img" \) | head -n 1 || true)

    echo "[*] Initrd search result: $initrd_src"

    # If initrd is found, check the same directory for the kernel
    if [[ -n "$initrd_src" ]]; then
        # Get the directory where initrd is located
        initrd_dir=$(dirname "$initrd_src")

        echo "[*] Searching for kernel in: $initrd_dir"

        # Now, search for kernel (vmlinuz* or bzImage*) in the same directory as initrd
        kernel_src=$(find "$initrd_dir" -type f \( -iname "vmlinu*" -o -iname "bzImage*" -o -iname "linux*" \) | head -n 1 || true)

        echo "[*] Kernel search result: $kernel_src"
    fi

    # Check if both kernel and initrd were found
    if [[ -n "$kernel_src" && -n "$initrd_src" ]]; then
        echo "[*] Success: kernel and initrd found."
        return 0  # Success
    else
        echo "ERROR: Kernel or Initrd not found for $path"
        return 1  # Failure
    fi
}

# ============================================================
# DETECT SQUASHFS LAYOUT
# ============================================================

detect_layout() {
    local path="$1"
    # FIXME: TODO: THIS IS WRONG MY UBUNTU HAVE DIFFERENT PATH BUT MAYBE OK FOR DEBIAN. JUST HECK CASPER DIR.
    # KICK FUNCTION AND USE casper string in rootfs
    if [ -f "$path/casper/filesystem.squashfs" ]; then echo "casper"
    elif [ -f "$path/live/filesystem.squashfs" ]; then echo "live"
    elif [ -f "$path/LiveOS/squashfs.img" ]; then echo "liveos"
    elif [ -f "$path/arch/x86_64/airootfs.sfs" ]; then echo "archiso"
    else echo "generic"
    fi
}

# ============================================================
# LINUX KERNEL PARAMS
# ============================================================

linux_params() {
    local family="$1"
    local folder="$2"
    local path="$3"
    local layout
    layout=$(detect_layout "$path")

    case "$family" in
        ubuntu)
            # with this writing into /cdrom can wipe ntfs partition
            # echo "boot=casper live-media=/dev/disk/by-label/$NTFS_LABEL live-media-path=/iso/$folder/casper quiet splash ---"
            # still cdrom, copilot was wrong
            echo "boot=casper root=live:$NTFS_LABEL live-media-path=/iso/$folder/casper quiet splash ---"
            ;;
        debian)
            if [ "$layout" = "casper" ]; then
                # with this writing into /cdrom can wipe ntfs partition
                echo "boot=casper live-media=/dev/disk/by-label/$NTFS_LABEL live-media-path=/iso/$folder/casper quiet splash ---"
            else
                echo "boot=live live-media=/dev/disk/by-label/$NTFS_LABEL live-media-path=/iso/$folder/live quiet splash ---"
            fi
            ;;
        redhat)
            #echo "inst.stage2=/iso/$folder quiet"
            #fedora hacked until it worked:
            echo "root=live:LABEL=$NTFS_LABEL rd.live.image rd.live.dir=/iso/$folder/LiveOS quiet"
            ;;
        opensuse)
            echo "install=/iso/$folder"
            ;;
        arch)
            echo "archisodevice=/dev/disk/by-label/$NTFS_LABEL img_dev=/dev/disk/by-label/$NTFS_LABEL img_loop=/iso/$folder/arch/x86_64/airootfs.sfs"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ============================================================
# DETECT BROKEN LOOPBACK ISOS (openSUSE, RHEL-family, etc.)
# ============================================================

is_broken_loopback_iso() {
    local path="$1"

    # openSUSE (Leap / Tumbleweed)
    if [ -f "$path/boot/x86_64/loader/linux" ] && \
       [ -f "$path/boot/x86_64/loader/initrd" ]; then
        echo "opensuse"
        return 0
    fi

    # RHEL / CentOS / Rocky / Alma / Fedora Server / Everything
    if [ -f "$path/images/install.img" ]; then
        echo "rhel-like"
        return 0
    fi

    return 1
}

# ============================================================
# EXTRACT AND PARSE loopback.cfg FROM ISO
# ============================================================

extract_loopback_cfg() {
    local iso="$1"
    local mountdir
    mountdir=$(mktemp -d)

    # Mount ISO read-only
    if ! mount -o loop,ro "$iso" "$mountdir" 2>/dev/null; then
        rmdir "$mountdir"
        return 1
    fi

    # Detect broken loopback ISOs
    local broken_family
    if broken_family=$(is_broken_loopback_iso "$mountdir"); then
        echo "[!] Detected broken loopback ISO ($broken_family) — not using loopback boot for this ISO"
        umount "$mountdir"
        rmdir "$mountdir"
        return 3
    fi

    # Search common loopback.cfg locations
    local cfg=""
    for p in \
        "$mountdir/boot/grub/loopback.cfg" \
        "$mountdir/boot/grub2/loopback.cfg" \
        "$mountdir/EFI/BOOT/loopback.cfg" \
        "$mountdir/loader/loopback.cfg"
    do
        if [ -f "$p" ]; then
            cfg="$p"
            break
        fi
    done

    if [[ -z "$cfg" ]]; then
        umount "$mountdir"
        rmdir "$mountdir"
        return 1
    fi

    # Fedora-style fake loopback.cfg detection
    if grep -qE '^[[:space:]]*source[[:space:]]+/boot/grub2/grub.cfg' "$cfg"; then
        echo "[*] Fedora-style fake loopback.cfg detected — ignoring"
        umount "$mountdir"
        rmdir "$mountdir"
        return 2
    fi

    # Copy out the file to a temp path
    LOOPBACK_TMP=$(mktemp)
    cp "$cfg" "$LOOPBACK_TMP"

    umount "$mountdir"
    rmdir "$mountdir"
    return 0
}

generate_entry_from_loopback() {
    local iso="$1"
    local base="$2"
    local tmp="$LOOPBACK_TMP"

    # Extract first linux/initrd lines
    local linux_line initrd_line
    linux_line=$(grep -E "^[[:space:]]*(linux|linuxefi)[[:space:]]" "$tmp" | head -n1 || true)
    initrd_line=$(grep -E "^[[:space:]]*(initrd|initrdefi)[[:space:]]" "$tmp" | head -n1 || true)

    if [[ -z "$linux_line" || -z "$initrd_line" ]]; then
        echo "[*] loopback.cfg incomplete — falling back"
        return 1
    fi

    # Rewrite ISO filename and device labels in kernel parameters
    linux_line=$(echo "$linux_line" \
        | sed "s|iso-scan/filename=[^ ]*|iso-scan/filename=/iso/$iso|" \
        | sed "s|findiso=[^ ]*|findiso=/iso/$iso|" \
        | sed "s|img_loop=[^ ]*|img_loop=/iso/$iso|" \
        | sed "s|archisolabel=[^ ]*|archisolabel=$NTFS_LABEL|" \
        | sed "s|img_dev=[^ ]*|img_dev=/dev/disk/by-label/$NTFS_LABEL|" \
        | sed "s|root=live:CDLABEL=[^ ]*|root=live:CDLABEL=$NTFS_LABEL|" \
        | sed "s|CDLABEL=[^ ]*|CDLABEL=$NTFS_LABEL|")

    # Write GRUB entry using the ISO's own config logic
    cat >> "$GRUB_CFG" <<EOF
menuentry "$base (loopback.cfg)" {
    search --file --set=root /boot/grub-bstick/$GRUB_DIR_NAME/grub.cfg
    regexp --set=1:disk '^([^,]*).*$' \$root
    set isodev="(\$disk,gpt2)"
    loopback loop \$isodev/iso/$iso

    $linux_line
    $initrd_line
}
EOF

    echo "[*] Added loopback.cfg entry for $iso"
    return 0
}

# ============================================================
# UNIFIED WINDOWS CHAINLOADER ENTRY
# ============================================================

add_windows_chainloader() {
    local title="$1"
    local efi_relpath="$2"

    cat >> "$GRUB_CFG" <<EOF
menuentry "$title" {
    search --file --set=root /boot/grub-bstick/$GRUB_DIR_NAME/grub.cfg
    regexp --set=1:disk '^([^,]*).*$' \$root
    set ntfsdev="(\$disk,gpt2)"
    chainloader \$ntfsdev/$efi_relpath
}
EOF
}

# ============================================================
# PROCESS WINDOWS SOURCE (ISO + WTG)
# ============================================================

process_windows_source() {
    local folder="$1"
    local path="$2"

    echo "[*] Looking at $folder"

    local efi=""
    if [ -f "$path/efi/boot/bootx64.efi" ]; then
        efi="iso/$folder/efi/boot/bootx64.efi"
    elif [ -f "$path/EFI/BOOT/BOOTX64.EFI" ]; then
        efi="iso/$folder/EFI/BOOT/BOOTX64.EFI"
    elif [ -f "$path/efi/microsoft/boot/bootmgfw.efi" ]; then
        mkdir -p "$path/efi/boot"
        cp "$path/efi/microsoft/boot/bootmgfw.efi" "$path/efi/boot/bootx64.efi"
        efi="iso/$folder/efi/boot/bootx64.efi"
    elif [ -f "$path/EFI/MICROSOFT/BOOT/BOOTMGFW.EFI" ]; then
        mkdir -p "$path/EFI/BOOT"
        cp "$path/EFI/MICROSOFT/BOOT/BOOTMGFW.EFI" "$path/EFI/BOOT/BOOTX64.EFI"
        efi="iso/$folder/EFI/BOOT/BOOTX64.EFI"
    fi

    [[ -n "$efi" ]] || return

    add_windows_chainloader "$folder (Windows)" "$efi"
    echo "[*] Added Grub Windows entry for $folder."
}

# ============================================================
# MAIN LOOP — ISO FILES + EXTRACTED DIRECTORIES
# ============================================================

for item in "$ISO_DIR"/*; do
    name=$(basename "$item")

    # ============================================================
    # CASE 1: ISO FILE → create loopback entry
    # ============================================================
    if [[ -f "$item" && "$item" == *.iso ]]; then
        iso="$name"
        base="${iso%.iso}"
        family=$(detect_family "$base")

        echo "[*] Found ISO file: $iso (family: $family)"

        # Try loopback.cfg / broken-loopback detection first
        if extract_loopback_cfg "$item"; then
            # extract_loopback_cfg returned 0: we have a usable loopback.cfg
            if generate_entry_from_loopback "$iso" "$base"; then
                rm -f "$LOOPBACK_TMP"
                continue
            else
                rm -f "$LOOPBACK_TMP"
                echo "[*] loopback.cfg parsing failed, falling back to manual entry"
            fi
        else
            rc=$?
            if [ "$rc" -eq 3 ]; then
                # broken loopback ISO detected — do NOT try loopback boot
                echo "[!] $iso is not loopback-bootable; skipping ISO loopback entry"
                # You could instead suggest: "extract ISO to directory and reuse extracted mode"
                continue
            fi
            # rc 1 or 2: no loopback.cfg or fake one; fall back to manual logic
        fi

        # ------------------------------
        # Per‑distro loopback logic (fallback)
        # ------------------------------
        case "$family" in
            ubuntu|debian)
                kernel_path="(loop)/casper/vmlinuz"
                initrd_path="(loop)/casper/initrd"
                params="iso-scan/filename=/iso/$iso quiet splash ---"
                ;;
            redhat)
                kernel_path="(loop)/isolinux/vmlinuz"
                initrd_path="(loop)/isolinux/initrd.img"
                # for install cd but not live?
                params="inst.stage2=hd:LABEL=$NTFS_LABEL:/iso/$iso quiet"
                ;;
            opensuse)
                kernel_path="(loop)/boot/x86_64/loader/linux"
                initrd_path="(loop)/boot/x86_64/loader/initrd"
                params="install=hd:LABEL=$NTFS_LABEL:/iso/$iso"
                ;;
            arch)
                kernel_path="(loop)/arch/boot/x86_64/vmlinuz-linux"
                initrd_path="(loop)/arch/boot/x86_64/archiso.img"
                params="img_dev=/dev/disk/by-label/$NTFS_LABEL img_loop=/iso/$iso"
                ;;
            windows*)
                # Windows ISO → chainload bootx64.efi
                cat >> "$GRUB_CFG" <<EOF
menuentry "$base (Windows ISO)" {
    search --file --set=root /boot/grub-bstick/$GRUB_DIR_NAME/grub.cfg
    regexp --set=1:disk '^([^,]*).*$' \$root
    set ntfsdev="(\$disk,gpt2)"
    loopback loop \$ntfsdev/iso/$iso
    chainloader (loop)/efi/boot/bootx64.efi
}
EOF
                echo "[*] Added Windows ISO loopback entry for $iso"
                continue
                ;;
            *)
                # Generic fallback
                kernel_path="(loop)/casper/vmlinuz"
                initrd_path="(loop)/casper/initrd"
                params="iso-scan/filename=/iso/$iso quiet splash ---"
                ;;
        esac

        # ------------------------------
        # Write GRUB entry (fallback)
        # ------------------------------
        cat >> "$GRUB_CFG" <<EOF
menuentry "$base (ISO loopback)" {
    search --file --set=root /boot/grub-bstick/$GRUB_DIR_NAME/grub.cfg
    regexp --set=1:disk '^([^,]*).*$' \$root
    set isodev="(\$disk,gpt2)"
    loopback loop \$isodev/iso/$iso
    linux $kernel_path $params
    initrd $initrd_path
}
EOF

        echo "[*] Added loopback ISO entry for $iso"
        continue
    fi

    # ============================================================
    # CASE 2: DIRECTORY → existing extracted‑ISO logic
    # ============================================================
    [[ -d "$item" ]] || continue

    folder="$name"
    family=$(detect_family "$folder")

    echo "[*] Found extracted ISO directory: $folder (family: $family)"

    case "$family" in
        windows*|windows)
            process_windows_source "$folder" "$item"
            ;;

        ubuntu|debian|redhat|opensuse|arch)
            if find_kernel_initrd "$item"; then
                bootdir="$MNT_EFI/boot/$folder"

                if [ ! -d "$bootdir" ]; then
                    mkdir -p "$bootdir"
                    cp "$kernel_src" "$bootdir/vmlinuz"
                    cp "$initrd_src" "$bootdir/initrd"
                    echo "[*] Copied kernel+initrd to EFI partition"
                else
                    echo "[*] Kernel+initrd already present"
                fi

                params=$(linux_params "$family" "$folder" "$item")

                cat >> "$GRUB_CFG" <<EOF
menuentry "$folder (Linux)" {
    search --file --set=root /boot/grub-bstick/$GRUB_DIR_NAME/grub.cfg
    regexp --set=1:disk '^([^,]*).*$' \$root
    set efidev="(\$disk,gpt1)"
    linux \$efidev/boot/$folder/vmlinuz $params
    initrd \$efidev/boot/$folder/initrd
}
EOF
                echo "[*] Added extracted‑ISO Linux entry for $folder"
            else
                echo "ERROR: No kernel/initrd found in $folder"
            fi
            ;;
    esac
done


# ============================================================
# CLEANUP
# ============================================================

umount "$MNT_EFI" || true
umount "$MNT_NTFS" || true
rm -r "$MNT_EFI" "$MNT_NTFS"

echo "[*] Multiboot USB updated."

