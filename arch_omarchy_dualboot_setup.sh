#!/usr/bin/env bash
# ==============================================================================
# Arch Linux Full Installer – Dualboot + Limine + Encryption + Snapper + Plymouth
# Windows-safe dualboot (creates separate Arch EFI)
# Production-Ready Version (2025)
# ==============================================================================

set -euo pipefail
trap 'cleanup' ERR

HOSTNAME=${HOSTNAME:-arch}
LOCALE=${LOCALE:-en_US.UTF-8}
TIMEZONE=${TIMEZONE:-UTC}
SWAP_SIZE=${SWAP_SIZE:-4G}

LOG_FILE="/tmp/arch_install_$(date +%Y%m%d_%H%M%S).log"
TMP_MOUNT="/mnt/__tmp"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "📘 Logging to: $LOG_FILE"

if [[ $EUID -ne 0 ]]; then
    echo "⚠️  This script requires root privileges."
    echo "🔑 Tentative elevation... (sudo)"
    if ! sudo -v; then
       echo "❌ Sudo authentication failed. Please run as root."
       exit 1
    fi
    exec sudo "$0" "$@"
fi

# Check dependencies
for cmd in whiptail parted lsblk cryptsetup mkfs.btrfs; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Missing dependency: $cmd"
        exit 1
    fi
done

mkdir -p "$TMP_MOUNT"

TARGET_DISK=""
EFI_DEV=""
ROOT_DEV=""
EFI_PART_NUM=""
ROOT_UUID=""
LUKS_UUID=""
ENCRYPT_DISK=""

# ==============================================================================
# Cleanup
# ==============================================================================
cleanup() {
    echo "🧹 Cleaning up..."
    umount -R /mnt 2>/dev/null || true
    umount "$TMP_MOUNT" 2>/dev/null || true
    cryptsetup luksClose root 2>/dev/null || true
    rm -rf "$TMP_MOUNT"
}
# ==============================================================================
# Graceful Exit
# ==============================================================================
exit_safe() {
    echo "🚫 Installation aborted by user."
    cleanup
    exit 0
}

# ==============================================================================
# Helper: Get max contiguous free space in Bytes
# ==============================================================================
# Helper: Get max contiguous free space in Bytes
# ==============================================================================
get_max_free_space() {
    # output: 10737418240 (bytes)
    # We parse 'parted -m unit B print free'
    # Format: 1:32256B:1073741823B:1073709568B:free;
    # We look for 'free;' lines and take the 4th column (size)
    # Sort numeric descending and take head -1
    parted -m -s "$TARGET_DISK" unit B print free 2>/dev/null | grep ':free;' | awk -F: '{print $4}' | sed 's/B$//' | sort -rn | head -n1 || echo "0"
}

# ==============================================================================
# Helper: Get partition device path (handles nvme p-suffix vs sda)
# ==============================================================================
get_partition_path() {
    local DISK=$1
    local NUM=$2
    if [[ "$DISK" =~ [0-9]$ ]]; then
        echo "${DISK}p${NUM}"
    else
        echo "${DISK}${NUM}"
    fi

}

# ==============================================================================
# Helper: Get largest free segment (Start, End, Size in Bytes)
# ==============================================================================
get_largest_free_segment() {
    # Output: START_B END_B SIZE_B
    # parted -m unit B print free
    # Format: 1:32256B:1073741823B:1073709568B:free;
    # Sort by size (col 4) desc -> take top 1
    local LINE
    LINE=$(parted -m -s "$TARGET_DISK" unit B print free 2>/dev/null | grep ':free;' | sort -t: -k4 -rn | head -n1)
    
    if [[ -z "$LINE" ]]; then
        echo "0 0 0"
        return
    fi
    
    local START_B END_B SIZE_B
    # Strip 'B' suffix
    START_B=$(echo "$LINE" | cut -d: -f2 | tr -d 'B')
    END_B=$(echo "$LINE" | cut -d: -f3 | tr -d 'B')
    SIZE_B=$(echo "$LINE" | cut -d: -f4 | tr -d 'B')
    
    echo "$START_B $END_B $SIZE_B"
}

# ==============================================================================
# Helper: Convert IEC size (1G, 500M) to bytes
# ==============================================================================
convert_to_bytes() {
    local INPUT=$1
    if [[ "$INPUT" =~ ^[0-9]+$ ]]; then
        echo "$INPUT"
    else
        # numfmt handles K, M, G suffixes (IEC standard)
        numfmt --from=iec "$INPUT" 2>/dev/null || echo "0"
    fi
}

# ==============================================================================
# Disk selection

# ==============================================================================
# Disk selection
# ==============================================================================
select_disk() {
    if [[ -n "${AUTO_DISK:-}" ]]; then
        TARGET_DISK="$AUTO_DISK"
        return
    fi

    # Build menu options
    local -a OPTIONS=()
    while IFS= read -r line; do
        eval "$line"
        [[ "${TYPE:-}" == "disk" ]] || continue
        # Create a readable label: "Model - Size"
        local LABEL="${MODEL:-Unknown} - ${SIZE:-?}"
        OPTIONS+=("/dev/$NAME" "$LABEL")
    done < <(lsblk -P -o NAME,TYPE,SIZE,MODEL,TRAN)

    if [[ ${#OPTIONS[@]} -eq 0 ]]; then
        whiptail --title "Error" --msgbox "No disks found!" 10 40
        exit 1
    fi

    TARGET_DISK=$(whiptail --title "Select Disk" --menu "Choose the target disk for installation:" 15 60 5 "${OPTIONS[@]}" 3>&1 1>&2 2>&3) || exit_safe
    
    # Ask for encryption preference
    if (whiptail --title "Encryption" --yesno "Enable disk encryption (LUKS)?" 10 50); then
        ENCRYPT_DISK="yes"
    else
        ENCRYPT_DISK="no"
    fi
}

# ==============================================================================
# Manage Partitions (Delete option)
# ==============================================================================
manage_partitions() {
    # Check free space first
    local FREE_BYTES
    FREE_BYTES=$(get_max_free_space)
    local MIN_BYTES=8589934592 # 8 GB

    # Convert to Human Readable for display
    local FREE_HR
    FREE_HR=$(numfmt --to=iec --suffix=B "$FREE_BYTES")

    local MSG
    local TITLE="Partition Management"
    local DEFAULT_NO="--defaultno" # Default to skipping if space is enough

    if (( FREE_BYTES >= MIN_BYTES )); then
        MSG="✅ Free Space Detected: $FREE_HR (Sufficient)\n\nYou have enough space to install Arch.\n\nDo you want to DELETE partitions anyway?"
        # Standard yes/no. Yes = Manage, No = Skip.
    else
        MSG="⚠️  LOW DISK SPACE WARNING: $FREE_HR\n\nArch Linux requires at least 8GB.\n\nIt is HIGHLY RECOMMENDED using the partition manager to delete partitions and free up space.\n\nEnter Partition Manager?"
        TITLE="⚠️ LOW SPACE WARNING"
        DEFAULT_NO="" # Default to Yes (Manage)
    fi

    if ! whiptail --title "$TITLE" --yesno "$MSG" 15 60 $DEFAULT_NO; then
        return
    fi

    while true; do
        # List partitions
        local -a PART_OPTIONS=()
        while IFS= read -r line; do
             eval "$line"
             [[ "${TYPE:-}" == "part" ]] || continue
             # Skip if it's not on the target disk (simple check)
             [[ "/dev/$NAME" == "$TARGET_DISK"* ]] || continue
             
             local LABEL="${FSTYPE:-unknown} - ${SIZE:-?}"
             # Check if partition number can be extracted
             local LABEL="${FSTYPE:-unknown} - ${SIZE:-?}"
             # Check if partition number can be extracted
             # Logic: Extract trailing digits
             if [[ "$NAME" =~ [0-9]+$ ]]; then
                local PNUM
                PNUM=$(echo "$NAME" | grep -o '[0-9]*$')
                PART_OPTIONS+=("$PNUM" "$LABEL /dev/$NAME" "OFF")
             fi
        done < <(lsblk -P -o NAME,TYPE,FSTYPE,SIZE)
        
        if [[ ${#PART_OPTIONS[@]} -eq 0 ]]; then
            whiptail --title "Info" --msgbox "No partitions found on $TARGET_DISK to delete." 10 50
            break
        fi

        local SELECTIONS
        SELECTIONS=$(whiptail --title "Delete Partitions" --checklist \
            "Select partitions to DELETE (Space to select, Enter to confirm). CANCEL to finish." \
            20 70 10 "${PART_OPTIONS[@]}" 3>&1 1>&2 2>&3)
        
        # Check if user cancelled or selected nothing
        [[ $? -ne 0 ]] && break
        [[ -z "$SELECTIONS" ]] && break

        # SELECTIONS comes as '"1" "2"'
        # Strip quotes
        SELECTIONS="${SELECTIONS//\"/}"
        
        if (whiptail --title "WARNING" --yesno "Are you sure you want to PERMANENTLY DELETE partitions: $SELECTIONS?" 10 60 --defaultno); then
            # Delete in reverse order to avoid shifting issues if any?
            # Sort descending
            local SORTED_SELS
            IFS=' ' read -r -a SEL_ARRAY <<< "$SELECTIONS"
            # simple sort
            SORTED_SELS=$(printf "%s\n" "${SEL_ARRAY[@]}" | sort -nr)
            
            for part_num in $SORTED_SELS; do
                parted -s "$TARGET_DISK" rm "$part_num" || whiptail --msgbox "Failed to delete partition $part_num" 8 40
            done
            partprobe "$TARGET_DISK"
            sleep 1
        fi
    done
}

# ==============================================================================
# Partition disk
# ==============================================================================
partition_disk() {
    # Detect existing Windows EFI
    WIN_EFI_DEV=$(blkid -t TYPE=vfat -o device | while read p; do
        TMP=$(mktemp -d)
        mount -o ro "$p" "$TMP" 2>/dev/null || continue
        if [[ -d "$TMP/EFI/Microsoft" ]]; then
            echo "$p"
        fi
        umount "$TMP" 2>/dev/null
        rmdir "$TMP"
    done | head -n1)



    # Check for any partitions
    local HAS_PARTITIONS="no"
    if lsblk -n --output TYPE "$TARGET_DISK" | grep -q "part"; then
        HAS_PARTITIONS="yes"
    fi

    if [[ -n "$WIN_EFI_DEV" ]] || [[ "$HAS_PARTITIONS" == "yes" ]]; then
        local TITLE="Existing Partitions"
        local MSG="Partitions detected on $TARGET_DISK.\n\nI will NOT wipe the disk automatically. You must specify free space for Arch.\n\n(I will create a separate Arch EFI to avoid conflict if EFI exists)."

        if [[ -n "$WIN_EFI_DEV" ]]; then
             TITLE="Windows Detected"
             MSG="Windows EFI detected on $WIN_EFI_DEV.\n\n$MSG"
        fi

        whiptail --title "$TITLE" --msgbox "$MSG" 15 60
        parted --script "$TARGET_DISK" unit GB print free > /tmp/part_layout
        whiptail --title "Current Partitions" --textbox /tmp/part_layout 20 70

        whiptail --title "Current Partitions" --textbox /tmp/part_layout 20 70

        # Get Free Space Info
        read -r START_B END_B SIZE_B <<< $(get_largest_free_segment)
        SIZE_HR=$(numfmt --to=iec --suffix=B "$SIZE_B")

        if (( SIZE_B < 5368709120 )); then # 5GB Check
             whiptail --title "Error" --msgbox "Only $SIZE_HR free space found. Arch requires at least 5GB.\nPlease delete partitions first." 10 50
             exit_safe
        fi

        # Determine next available partition number
        LAST_NUM=$(parted -m "$TARGET_DISK" print | awk -F: '/^Number/{next}{n=$1}END{print n}')
        EFI_PART_NUM=$((LAST_NUM + 1))
        ROOT_PART_NUM=$((EFI_PART_NUM + 1))

        # Menu: Auto vs Custom
        local METHOD
        METHOD=$(whiptail --title "Partition Method" --menu "Available Free Space: $SIZE_HR\nSelect how to partition:" 15 60 2 \
            "Auto" "Use 1GB for EFI + Rest for Root" \
            "Custom" "Specify partition sizes (e.g. 512M)" 3>&1 1>&2 2>&3) || exit_safe

        local EFI_SIZE_B ROOT_SIZE_B
        
        if [[ "$METHOD" == "Auto" ]]; then
            EFI_SIZE_B=1073741824 # 1GiB
            # Root is remainder
        else
            # Custom
            local INPUT_EFI
            INPUT_EFI=$(whiptail --inputbox "Enter EFI Size (e.g. 512M, 1G):" 10 50 "1G" --title "Custom Size" 3>&1 1>&2 2>&3) || exit_safe
            EFI_SIZE_B=$(convert_to_bytes "$INPUT_EFI")
            
            # Validation
            if (( EFI_SIZE_B < 33554432 )); then # 32MB min
                whiptail --msgbox "EFI size too small!" 8 40
                exit_safe
            fi

            local REMAINING_B=$(( SIZE_B - EFI_SIZE_B ))
            local REMAINING_HR=$(numfmt --to=iec --suffix=B "$REMAINING_B")
            
            local INPUT_ROOT
            INPUT_ROOT=$(whiptail --inputbox "Enter Root Size (e.g. 20G).\nLeave EMPTY to use remaining ($REMAINING_HR):" 12 50 --title "Custom Size" 3>&1 1>&2 2>&3) || exit_safe
            
            if [[ -z "$INPUT_ROOT" ]]; then
                # Use remaining
                ROOT_SIZE_B=0
            else
                ROOT_SIZE_B=$(convert_to_bytes "$INPUT_ROOT")
            fi
        fi

        # Calculate Coords
        # EFI
        local EFI_START=$START_B
        local EFI_END=$(( EFI_START + EFI_SIZE_B ))
        
        # Validate EFI fits
        if (( EFI_END > END_B )); then
             whiptail --msgbox "Error: Not enough space for EFI partition!" 8 40
             exit_safe
        fi

        # Root
        local ROOT_START=$EFI_END
        local ROOT_END
        if [[ "${ROOT_SIZE_B:-0}" -eq 0 ]]; then
            ROOT_END=$END_B
        else
            ROOT_END=$(( ROOT_START + ROOT_SIZE_B ))
        fi

        # Validate Root fits
        if (( ROOT_END > END_B )); then
             whiptail --msgbox "Error: Not enough space for Root partition!" 8 40
             exit_safe
        fi

        echo "🧩 Creating Arch EFI ($EFI_START -> $EFI_END) and Root ($ROOT_START -> $ROOT_END)..."

        # Create Arch EFI and root (using bytes 'B' unit)
        parted --script "$TARGET_DISK" mkpart primary fat32 "${EFI_START}B" "${EFI_END}B"
        parted --script "$TARGET_DISK" set "$EFI_PART_NUM" esp on
        parted --script "$TARGET_DISK" name "$EFI_PART_NUM" "ARCH_EFI"
        parted --script "$TARGET_DISK" mkpart primary btrfs "${ROOT_START}B" "${ROOT_END}B"
        parted --script "$TARGET_DISK" name "$ROOT_PART_NUM" "ARCH_ROOT"

        # Refresh partition table
        partprobe "$TARGET_DISK"
        sync
        sleep 3

        # Update global vars
        EFI_DEV=$(get_partition_path "$TARGET_DISK" "$EFI_PART_NUM")
        ROOT_DEV=$(get_partition_path "$TARGET_DISK" "$ROOT_PART_NUM")

        echo "✅ Partitions ready:"
        echo "   • EFI:  $EFI_DEV (part $EFI_PART_NUM)"
        echo "   • ROOT: $ROOT_DEV"
    else
        # Disk is EMPTY case
        # Only now do we offer to wipe/format from scratch
        if ! whiptail --title "Empty Disk Setup" --yesno "Disk $TARGET_DISK appears empty.\n\nInitialize with default Arch layout (Wipe & Auto-Partition)?\n\n(Creates: 2GB EFI + Remaining Root)" 15 60 --defaultno; then
            exit_safe
        fi

        parted --script "$TARGET_DISK" mklabel gpt
        parted --script "$TARGET_DISK" mkpart primary fat32 1MiB 2049MiB
        parted --script "$TARGET_DISK" set 1 esp on
        parted --script "$TARGET_DISK" name 1 "ARCH_EFI"
        parted --script "$TARGET_DISK" mkpart primary btrfs 2049MiB 100%
        parted --script "$TARGET_DISK" name 2 "ARCH_ROOT"

        partprobe "$TARGET_DISK"
        sync
        sleep 3

        partprobe "$TARGET_DISK"
        sync
        sleep 3

        EFI_DEV=$(get_partition_path "$TARGET_DISK" "1")
        ROOT_DEV=$(get_partition_path "$TARGET_DISK" "2")

        echo "✅ Partitions ready:"
        echo "   • EFI:  $EFI_DEV (part 1)"
        echo "   • ROOT: $ROOT_DEV (part 2)"
    fi
}



# ==============================================================================
# Filesystem setup (Encryption optional)
# ==============================================================================
setup_filesystem() {
    local DRIVE_TO_MOUNT
    if [[ "$ENCRYPT_DISK" == "yes" ]]; then
        local LUKS_PASS
        if [[ -n "${AUTO_LUKS_PASS:-}" ]]; then
            LUKS_PASS="$AUTO_LUKS_PASS"
        else
            while true; do
                LUKS_PASS=$(whiptail --title "Encryption" --passwordbox "Enter LUKS passphrase:" 10 50 3>&1 1>&2 2>&3) || exit 1
                LUKS_PASS2=$(whiptail --title "Encryption" --passwordbox "Confirm passphrase:" 10 50 3>&1 1>&2 2>&3) || exit 1
                
                [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] && break
                whiptail --msgbox "Passphrases mismatch. Try again." 8 40
            done
        fi

        printf "%s" "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --force-password "$ROOT_DEV" -
        printf "%s" "$LUKS_PASS" | cryptsetup open "$ROOT_DEV" root
        
        DRIVE_TO_MOUNT="/dev/mapper/root"
        mkfs.btrfs -f "$DRIVE_TO_MOUNT"
        mount "$DRIVE_TO_MOUNT" /mnt
    else
        echo "📂 Setting up plain Btrfs on $ROOT_DEV ..."
        DRIVE_TO_MOUNT="$ROOT_DEV"
        mkfs.btrfs -f "$DRIVE_TO_MOUNT"
        mount "$DRIVE_TO_MOUNT" /mnt
    fi
    for sub in @ @home @snapshots @log @swap; do
        btrfs subvolume create "/mnt/$sub"
    done
    umount /mnt

    # Mount subvolumes
    mount -o noatime,compress=zstd,subvol=@ "$DRIVE_TO_MOUNT" /mnt
    mkdir -p /mnt/{home,.snapshots,var/log,boot}
    mount -o noatime,compress=zstd,subvol=@home "$DRIVE_TO_MOUNT" /mnt/home
    mount -o noatime,compress=zstd,subvol=@snapshots "$DRIVE_TO_MOUNT" /mnt/.snapshots
    mount -o noatime,compress=zstd,subvol=@log "$DRIVE_TO_MOUNT" /mnt/var/log

    # Format Arch EFI only
    if whiptail --title "Format EFI" --yesno "Format EFI partition $EFI_DEV?" 10 50; then
         mkfs.fat -F32 "$EFI_DEV"
    fi
    mount "$EFI_DEV" /mnt/boot

    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    if [[ "$ENCRYPT_DISK" == "yes" ]]; then
        LUKS_UUID=$(cryptsetup luksUUID "$ROOT_DEV")
        echo "EFI: $EFI_DEV | ROOT: $ROOT_DEV | LUKS_UUID=$LUKS_UUID"
    else
        echo "EFI: $EFI_DEV | ROOT: $ROOT_DEV | Plain Btrfs"
    fi
}

# ==============================================================================
# Base system
# ==============================================================================


# ==============================================================================
# Main
# ==============================================================================

whiptail --title "Welcome" --msgbox "🚀 Starting Arch Linux Installer (Filesystem Setup Only)" 10 60
select_disk
manage_partitions
partition_disk
setup_filesystem

whiptail --title "Complete" --msgbox "✅ Filesystem setup complete!\n\nMounts are ready at /mnt.\n\nYou can now run:\narchinstall --mount-point /mnt" 12 60

clear
echo "=============================================================================="
echo "✅ Filesystem setup complete!"
echo "📂 Mounts are ready at /mnt"
echo "------------------------------------------------------------------------------"
echo "👉 NEXT STEP: Run the following command to install Arch:"
echo ""
echo "   archinstall --mount-point /mnt"
echo ""
echo "⚠️  IMPORTANT: In archinstall, DO NOT touch 'Disk configuration' or 'Mount points'."
echo "    The drives are already mounted and ready."
echo "=============================================================================="