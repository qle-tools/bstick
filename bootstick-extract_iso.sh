#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

usage() {
    echo "Usage: $0 [--no-check] <target_dir> <src1> <src2> ..."
    echo
    echo "  <target_dir>  Must be an existing directory (will NOT be created)."
    echo "  <src>         ISO file or directory containing ISO files (globs allowed)."
    echo
    echo "By default, the script:"
    echo "  - exits if sources are invalid or contain no ISOs"
    echo "  - exits if the target directory already contains ISO files"
    echo "  - exits if a per-ISO output directory already exists in the target"
    echo
    echo "Use --no-check to WARN instead of EXIT on these validation errors."
    exit 1
}

NO_CHECK=false

# Parse optional flag
if [[ "${1:-}" == "--no-check" ]]; then
    NO_CHECK=true
    shift
fi

# Need at least target + one source
if (( $# < 2 )); then
    usage
fi

TARGET="$1"
shift

# Target must exist
if [[ ! -d "$TARGET" ]]; then
    echo "ERROR: Target directory does not exist: $TARGET"
    echo "Target directory must be created beforehand."
    exit 1
fi

# Check if there are any ISO files directly in the target dir
shopt -s nullglob
isos_in_target=("$TARGET"/*.iso)
shopt -u nullglob

if (( ${#isos_in_target[@]} > 0 )); then
    msg="ERROR: Target directory contains ISO files: $TARGET"
    if $NO_CHECK; then
        echo "WARNING: $msg (continuing due to --no-check)"
        echo "         Make sure this is really what you want."
    else
        echo "$msg"
        echo "Target directory is: $TARGET"
        echo "This usually indicates a mistake (ISOs should be in sources, not in target)."
        echo "If you are sure this is intentional, run again with --no-check."
        exit 1
    fi
fi

# GRUB-safe directory name sanitizer
sanitize() {
    local input="$1"
    input=$(printf '%s' "$input" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$input")
    input=$(printf '%s' "$input" | sed -E 's/[^A-Za-z0-9._-]+/_/g')
    input=$(printf '%s' "$input" | sed -E 's/^_+|_+$//g')
    printf '%s' "$input"
}

# Collect ISOs from all sources
declare -a ISO_LIST=()

for src in "$@"; do
    if [[ -f "$src" ]]; then
        # Single file
        if [[ "$src" == *.iso ]]; then
            ISO_LIST+=("$src")
        else
            msg="ERROR: Source file is not an ISO: $src"
            if $NO_CHECK; then
                echo "WARNING: $msg (ignored due to --no-check)"
            else
                echo "$msg"
                echo "Tip: use --no-check to ignore this error."
                exit 1
            fi
        fi

    elif [[ -d "$src" ]]; then
        # Directory: collect ISOs
        found=false
        while IFS= read -r iso; do
            ISO_LIST+=("$iso")
            found=true
        done < <(find "$src" -maxdepth 1 -type f -name '*.iso')

        if ! $found; then
            msg="ERROR: No ISO files found in directory: $src"
            if $NO_CHECK; then
                echo "WARNING: $msg (ignored due to --no-check)"
            else
                echo "$msg"
                echo "Tip: use --no-check to ignore this error."
                exit 1
            fi
        fi

    else
        msg="ERROR: Source does not exist: $src"
        if $NO_CHECK; then
            echo "WARNING: $msg (ignored due to --no-check)"
        else
            echo "$msg"
            echo "Tip: use --no-check to ignore this error."
            exit 1
        fi
    fi
done

# Ensure we have at least one ISO
if (( ${#ISO_LIST[@]} == 0 )); then
    echo "ERROR: No ISO files found in any source."
    echo "Tip: use --no-check to ignore this error."
    exit 1
fi

# Extract ISOs
for iso in "${ISO_LIST[@]}"; do
    base=$(basename "$iso")
    name="${base%.iso}"
    safe_name=$(sanitize "$name")
    out="$TARGET/$safe_name"

    # Skip if already extracted and non-empty
    if [[ -d "$out" && -n "$(ls -A "$out" 2>/dev/null)" ]]; then
        echo "Skipping (already extracted): $iso"
        continue
    fi

    echo "Extracting: $iso → $out"
    mkdir -p "$out"
    bsdtar -xf "$iso" -C "$out"
done
