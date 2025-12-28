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
NTFS_LABEL="GRUB-ISO-BOOT-STICK"

MNT_EFI="/mnt/usb-efi"
MNT_NTFS="/mnt/usb-ntfs"

ISO_DIR="$MNT_NTFS/iso"

# ============================================================
# MOUNT PARTITIONS
# ============================================================

mkdir -p "$MNT_EFI" "$MNT_NTFS"
mount "${USB_DEV}1" "$MNT_EFI" || true
mount "${USB_DEV}2" "$MNT_NTFS" || true

# ============================================================
# DETECT GRUB DIRECTORY
# ============================================================

if [ -d "$MNT_EFI/boot/grub" ]; then
    GRUB_DIR="$MNT_EFI/boot/grub"
elif [ -d "$MNT_EFI/boot/grub2" ]; then
    GRUB_DIR="$MNT_EFI/boot/grub2"
else
    echo "ERROR: No grub directory found"
    exit 1
fi

GRUB_CFG="$GRUB_DIR/grub.cfg"

# ============================================================
# BASE GRUB CONFIG
# ============================================================

cat > "$GRUB_CFG" <<EOF
set timeout=10
set default=0

menuentry "Reboot" { reboot }
menuentry "Power Off" { halt }
EOF

touch "$MNT_EFI/boot/grub-usb-stick.mark"

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
    local layout=$(detect_layout "$path")

    case "$family" in
        ubuntu)
            # with this writing into /cdrom can wipe ntfs partition
            # echo "boot=casper live-media=/dev/disk/by-label/$NTFS_LABEL live-media-path=/iso/$folder/casper quiet splash ---"
            # still cdrom, copilot was wrong
            echo "boot=casper root=live:$NTFS_LABEL live-media-path=/iso/$folder/casper quiet splash ---"
            # not working with ntfs because initrd has not ntfs support?
#             local rootfs
#             rootfs=$(find "$path/casper" -maxdepth 1 -type f -name '*.squashfs' -printf '%s %p\n' \
#                 | sort -nr | head -n1 | cut -d' ' -f2-)
#             echo "boot=casper findiso=/iso/$folder/casper/$(basename "$rootfs") quiet splash ---"
            ;;
        debian)
            if [ "$layout" = "casper" ]; then
                # with this writing into /cdrom can wipe ntfs partition
                echo "boot=casper live-media=/dev/disk/by-label/$NTFS_LABEL live-media-path=/iso/$folder/casper quiet splash ---"
                # still cdrom, copilot was wrong
                #echo "boot=casper root=live:$NTFS_LABEL live-media-path=/iso/$folder/casper quiet splash ---"
                # not working with ntfs because initrd has not ntfs support?
#                 local rootfs
#                 rootfs=$(find "$path/casper" -maxdepth 1 -type f -name '*.squashfs' -printf '%s %p\n' \
#                     | sort -nr | head -n1 | cut -d' ' -f2-)
#                 echo "boot=casper findiso=/iso/$folder/casper/$(basename "$rootfs") quiet splash ---"
            else
                echo "boot=live live-media=/dev/disk/by-label/$NTFS_LABEL live-media-path=/iso/$folder/live quiet splash ---"
            fi
            ;;
        redhat)
            echo "inst.stage2=/iso/$folder quiet"
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
# CHECK IF KERNEL IS SIGNED (to load it with linuxefi)
# ============================================================

use_signature_checking_loader() {
    local kernel="$1"

    # Detect PE/COFF signature wrapper
    if file "$kernel" | grep -q "PE32+" && [ -f "$GRUB_DIR/x86_64-efi/linuxefi.mod" ] ; then
        return 0  # signed
    else
        return 1  # unsigned
    fi
}


# ============================================================
# UNIFIED WINDOWS CHAINLOADER ENTRY
# ============================================================

add_windows_chainloader() {
    local title="$1"
    local efi_relpath="$2"

    cat >> "$GRUB_CFG" <<EOF
menuentry "$title" {
    search --file --set=root /boot/grub-usb-stick.mark
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

        # ------------------------------
        # Per‑distro loopback logic
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
    search --file --set=root /boot/grub-usb-stick.mark
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
        # Write GRUB entry
        # ------------------------------
        cat >> "$GRUB_CFG" <<EOF
menuentry "$base (ISO loopback)" {
    search --file --set=root /boot/grub-usb-stick.mark
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

                if use_signature_checking_loader "$kernel_src"; then
                    LINUX_CMD="linuxefi"
                    INITRD_CMD="initrdefi"
                else
                    LINUX_CMD="linux"
                    INITRD_CMD="initrd"
                fi

                cat >> "$GRUB_CFG" <<EOF
menuentry "$folder (Linux)" {
    search --file --set=root /boot/grub-usb-stick.mark
    regexp --set=1:disk '^([^,]*).*$' \$root
    set efidev="(\$disk,gpt1)"
    $LINUX_CMD \$efidev/boot/$folder/vmlinuz $params
    $INITRD_CMD \$efidev/boot/$folder/initrd
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
