#!/bin/bash

echo "=== LineageOS eMMC Flash Script ==="
echo "Requirements: Linux environment, Hekate, SD card, internet."
echo "Developed by sthetix - Version 1.0.1"

usage() {
    echo "Usage: $0 [--tempdir PATH]"
    echo "       NX_LOS_TEMP_DIR=/path/to/temp $0"
}

TEMP_DIR="${NX_LOS_TEMP_DIR:-/tmp/lineageos_temp}"
while [ $# -gt 0 ]; do
    case "$1" in
        --tempdir)
            if [ -z "$2" ]; then
                echo "Error: --tempdir requires a path."
                usage
                exit 1
            fi
            TEMP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Install dependencies
for cmd in curl jq sgdisk parted sha256sum; do
    if ! command -v $cmd &> /dev/null; then
        echo "Installing $cmd..."
        sudo apt update && sudo apt install -y $cmd || {
            echo "Error: Failed to install $cmd!"
            exit 1
        }
    fi
done

SD_MOUNT="/mnt/sdcard"
mkdir -p "$TEMP_DIR" || {
    echo "Error: Failed to create temp directory: $TEMP_DIR"
    exit 1
}
TEMP_DIR=$(cd "$TEMP_DIR" && pwd)
echo "Using temp directory: $TEMP_DIR"

# Function for windmill spinner
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ -d /proc/$pid ]; do
        local temp=${spinstr#?}
        printf " %c" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b"
    done
    printf "  \b\b"
}

get_file_size() {
    stat -c%s "$1" 2>/dev/null || {
        echo "Error: Failed to read file size for $1"
        exit 1
    }
}

check_sd_free_space() {
    local required_bytes=0
    local available_bytes=0
    local safety_margin=$((64 * 1024 * 1024))
    local android_ini_size

    for file in boot.img recovery.img nx-plat.dtimg bl31.bin bl33.bin boot.scr icon_android_hue.bmp bootlogo_android.bmp "$ZIP_FILE"; do
        required_bytes=$((required_bytes + $(get_file_size "$TEMP_DIR/$file")))
    done

    if [ "$DOWNLOAD_GAPPS" = "yes" ] && [ -n "$GAPPS_FILENAME" ]; then
        required_bytes=$((required_bytes + $(get_file_size "$TEMP_DIR/$GAPPS_FILENAME")))
    fi

    android_ini_size=$(cat <<'EOF' | wc -c
[LineageOS]
l4t=1
boot_prefixes=switchroot/android/
id=SWANDR
icon=switchroot/android/icon_android_hue.bmp
logopath=switchroot/android/bootlogo_android.bmp
r2p_action=self
usb3_enable=1
emmc=1
EOF
)
    required_bytes=$((required_bytes + android_ini_size + safety_margin))
    available_bytes=$(df -PB1 --output=avail "$SD_MOUNT" | tail -n 1 | tr -d ' ')

    if [ -z "$available_bytes" ]; then
        echo "Error: Failed to check free space on SD card."
        exit 1
    fi

    echo "Required SD space: $((required_bytes / 1024 / 1024)) MiB (including 64 MiB safety margin)"
    echo "Available SD space: $((available_bytes / 1024 / 1024)) MiB"

    if [ "$available_bytes" -lt "$required_bytes" ]; then
        echo "Error: Not enough free space on SD card."
        echo "Free up space or use a larger SD card, then run the script again."
        sudo umount "$SD_MOUNT"
        exit 1
    fi
}

# Step 1: Ask for Tablet or TV Version and MindTheGapps
echo "=== Step 1: Select LineageOS Version ==="
echo "Choose device type (both work on V1/V2/Lite 29GB or OLED 58GB):"
echo "1) Tablet  2) TV"
read -p "Enter 1 or 2: " CHOICE
DEVICE="nx_tab"
ZIP_SUFFIX="nx_tab"
GAPPS_SUFFIX="arm64"  # ARM64 for Tablet
if [ "$CHOICE" = "2" ]; then
    DEVICE="nx"
    ZIP_SUFFIX="nx"
    GAPPS_SUFFIX="arm64-ATV"  # ARM64 for TV (adjusted from arm-ATV)
fi
echo "Would you like to download the matching MindTheGapps package (ARM64)?"
read -p "Enter y/N: " GAPPS_CHOICE
DOWNLOAD_GAPPS="no"
if [ "$GAPPS_CHOICE" = "y" ] || [ "$GAPPS_CHOICE" = "Y" ]; then
    DOWNLOAD_GAPPS="yes"
fi

# Step 2: Download Files with Full SHA256 Check
echo "=== Step 2: Downloading LineageOS Files ==="
API_URL="https://download.lineageos.org/api/v2/devices/$DEVICE/builds"
echo "Fetching latest build from $API_URL..."
BUILD_JSON=$(curl -s "$API_URL")
if [ -z "$BUILD_JSON" ] || echo "$BUILD_JSON" | grep -q "error"; then
    echo "Error: API returned empty or errored response!"
    read -p "Press Enter to retry, or Ctrl+C to exit..." -r
    BUILD_JSON=$(curl -s "$API_URL")
    if [ -z "$BUILD_JSON" ]; then
        echo "Retry failed! Check https://download.lineageos.org/."
        exit 1
    fi
fi

echo "Parsing latest build..."
LATEST_BUILD=$(echo "$BUILD_JSON" | jq -r 'sort_by(.date) | .[-1]' 2>/dev/null)
if [ -z "$LATEST_BUILD" ]; then
    echo "Error: Failed to parse latest build!"
    exit 1
fi

VERSION=$(echo "$LATEST_BUILD" | jq -r '.version')
DATE=$(echo "$LATEST_BUILD" | jq -r '.date' | tr -d '-')
echo "Latest build: $VERSION-$DATE"

DOWNLOAD_URLS=($(echo "$LATEST_BUILD" | jq -r '.files[] | select(.url | contains("super_empty.img") | not) | .url'))
CHECKSUMS=($(echo "$LATEST_BUILD" | jq -r '.files[] | select(.url | contains("super_empty.img") | not) | .sha256'))
ZIP_FILE="lineage-$VERSION-$DATE-nightly-$ZIP_SUFFIX-signed.zip"

# Download and verify API files
for i in "${!DOWNLOAD_URLS[@]}"; do
    URL="${DOWNLOAD_URLS[$i]}"
    CHECKSUM="${CHECKSUMS[$i]}"
    FILENAME=$(basename "$URL")
    if [ -f "$TEMP_DIR/$FILENAME" ]; then
        echo "$FILENAME already downloaded, verifying SHA256..."
        echo "$CHECKSUM  $TEMP_DIR/$FILENAME" | sha256sum -c - >/dev/null 2>&1 || {
            echo "Error: SHA256 mismatch for existing $FILENAME! Re-downloading..."
            rm -f "$TEMP_DIR/$FILENAME"
            curl -L -o "$TEMP_DIR/$FILENAME" "$URL" || {
                echo "Error: Failed to re-download $FILENAME!"
                exit 1
            }
            echo "$CHECKSUM  $TEMP_DIR/$FILENAME" | sha256sum -c - || {
                echo "Error: Re-downloaded $FILENAME still fails SHA256 check!"
                exit 1
            }
            echo "Re-downloaded $FILENAME verified OK."
        }
    else
        echo "Downloading $FILENAME..."
        curl -L -o "$TEMP_DIR/$FILENAME" "$URL" || {
            echo "Error: Failed to download $FILENAME!"
            exit 1
        }
        echo "Verifying $FILENAME SHA256..."
        echo "$CHECKSUM  $TEMP_DIR/$FILENAME" | sha256sum -c - || {
            echo "Error: Downloaded $FILENAME fails SHA256 check!"
            exit 1
        }
    fi
    echo "$FILENAME verified OK."
done

# Static BMP files without SHA256 verification
declare -A STATIC_FILES
STATIC_FILES["bootlogo_android.bmp"]="https://wiki.lineageos.org/images/device_specific/nx/bootlogo_android.bmp"
STATIC_FILES["icon_android_hue.bmp"]="https://wiki.lineageos.org/images/device_specific/nx/icon_android_hue.bmp"

for FILENAME in "${!STATIC_FILES[@]}"; do
    URL="${STATIC_FILES[$FILENAME]}"
    if [ -f "$TEMP_DIR/$FILENAME" ]; then
        echo "$FILENAME already downloaded, skipping SHA256 (no official checksum available)."
    else
        echo "Downloading $FILENAME..."
        curl -L -o "$TEMP_DIR/$FILENAME" "$URL" || {
            echo "Error: Failed to download $FILENAME!"
            exit 1
        }
        echo "$FILENAME downloaded (no SHA256 verification available)."
    fi
done

# Download MindTheGapps if chosen in Step 1
if [ "$DOWNLOAD_GAPPS" = "yes" ]; then
    case "$VERSION" in
        "20.0") ANDROID_VERSION="13" ;;
        "21.0") ANDROID_VERSION="14" ;;
        "22.0" | "22.1") ANDROID_VERSION="15" ;;
        *) echo "Warning: Unknown LineageOS version $VERSION! Assuming Android 15."; ANDROID_VERSION="15" ;;
    esac
    GITHUB_API="https://api.github.com/repos/MindTheGapps/$ANDROID_VERSION.0.0-$GAPPS_SUFFIX/releases/latest"
    echo "Fetching latest MindTheGapps release from $GITHUB_API..."
    GAPPS_JSON=$(curl -s "$GITHUB_API")
    if [ -z "$GAPPS_JSON" ] || echo "$GAPPS_JSON" | grep -q "API rate limit exceeded"; then
        echo "Error: Failed to fetch GitHub API data! Rate limit might be exceeded."
        exit 1
    fi

    GAPPS_URL=$(echo "$GAPPS_JSON" | jq -r --arg ver "$ANDROID_VERSION" --arg suf "$GAPPS_SUFFIX" '.assets[] | select(.name | contains("MindTheGapps-\($ver).0.0-\($suf)") and contains("arm64") and endswith(".zip")) | .browser_download_url' | head -n 1)
    GAPPS_FILENAME=$(echo "$GAPPS_JSON" | jq -r --arg ver "$ANDROID_VERSION" --arg suf "$GAPPS_SUFFIX" '.assets[] | select(.name | contains("MindTheGapps-\($ver).0.0-\($suf)") and contains("arm64") and endswith(".zip")) | .name' | head -n 1)

    if [ -z "$GAPPS_URL" ] || ! echo "$GAPPS_URL" | grep -q "^https://github.com"; then
        echo "Error: Invalid or missing MindTheGapps ARM64 ZIP URL!"
        echo "Available assets:"
        echo "$GAPPS_JSON" | jq -r '.assets[].name'
        exit 1
    fi

    if [ -f "$TEMP_DIR/$GAPPS_FILENAME" ]; then
        echo "$GAPPS_FILENAME already downloaded, skipping..."
    else
        echo "Downloading $GAPPS_FILENAME..."
        curl -L -o "$TEMP_DIR/$GAPPS_FILENAME" "$GAPPS_URL" || {
            echo "Error: Failed to download $GAPPS_FILENAME from $GAPPS_URL!"
            exit 1
        }
        echo "$GAPPS_FILENAME downloaded successfully."
    fi
fi

echo "Checking all required files..."
REQUIRED_FILES=("boot.img" "recovery.img" "nx-plat.dtimg" "icon_android_hue.bmp" "bootlogo_android.bmp" "$ZIP_FILE" "bl31.bin" "bl33.bin" "boot.scr")
for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$TEMP_DIR/$file" ]; then
        echo "Error: Required file $file missing!"
        exit 1
    else
        echo "$file found."
    fi
done

echo "Downloads and verifications complete! Now mount your SD card..."
echo "1. In Hekate: 'Tools' > 'USB Tools' > 'Disable Read-Only' > 'SD Card', connect USB."
echo "2. In VMware: Ensure USB is passed through (VM > Removable Devices > Connect)."
read -p "Press Enter when SD card is connected via Hekate UMS..."

# Step 3: Copy Files to SD
echo "=== Step 3: Copying Files to SD Card ==="
echo "Detecting SD card..."
TIMEOUT=60
COUNT=0
SD_DEV=""
echo -n "Scanning"
while [ -z "$SD_DEV" ] && [ $COUNT -lt $TIMEOUT ]; do
    NEW_DISKS=$(lsblk -o NAME,SIZE,LABEL,TYPE | grep disk | grep -v "sda")
    if [ -n "$NEW_DISKS" ]; then
        echo -e "\nDetected devices:"
        echo "$NEW_DISKS"
        read -p "Enter SD card device (e.g., sdb) or 'retry' to wait: " SD_DEV
        if [ "$SD_DEV" = "retry" ]; then
            SD_DEV=""
            echo -n "Retrying"
        else
            SD_SIZE=$(lsblk -b -n -o SIZE /dev/$SD_DEV | head -n 1)
            SD_SIZE_GB=$(echo "scale=1; $SD_SIZE / 1024 / 1024 / 1024" | bc)
            echo "Selected: $SD_DEV ($SD_SIZE_GB GB)"
            if [ $(echo "$SD_SIZE_GB >= 25 && $SD_SIZE_GB <= 65" | bc) -eq 1 ]; then
                echo "Warning: Size ($SD_SIZE_GB GB) matches a Switch eMMC (29GB or 58GB), not an SD card!"
                read -p "Confirm this is your SD card, not eMMC? (y/N): " CONFIRM_SD
                if [ "$CONFIRM_SD" != "y" ] && [ "$CONFIRM_SD" != "Y" ]; then
                    SD_DEV=""
                    echo "Retrying detection..."
                fi
            fi
            if [ -n "$SD_DEV" ] && [ -b "/dev/$SD_DEV" ]; then
                break
            else
                echo "Error: Invalid device '$SD_DEV'! Retrying..."
                SD_DEV=""
            fi
        fi
    fi
    echo -n "."
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ -z "$SD_DEV" ]; then
    echo -e "\nAuto-detection timed out! Current devices:"
    lsblk -o NAME,SIZE,LABEL,TYPE
    read -p "Enter SD card device (e.g., sdb): " SD_DEV
    if [ ! -b "/dev/$SD_DEV" ]; then
        echo "Error: Invalid SD card device '$SD_DEV'!"
        exit 1
    fi
fi

sudo mkdir -p $SD_MOUNT
sudo mount /dev/${SD_DEV}1 $SD_MOUNT || {
    sudo mount /dev/$SD_DEV $SD_MOUNT || {
        echo "Error: Failed to mount SD card! Ensure it’s FAT32 and Hekate UMS is active."
        exit 1
    }
}
echo "SD card mounted at: $SD_MOUNT"
check_sd_free_space

echo -n "Copying files to SD card "
( sudo mkdir -p "$SD_MOUNT/switchroot/install" "$SD_MOUNT/switchroot/android" "$SD_MOUNT/bootloader/ini"
  for file in boot.img recovery.img nx-plat.dtimg; do
    sudo cp "$TEMP_DIR/$file" "$SD_MOUNT/switchroot/install/"
  done
  for file in bl31.bin bl33.bin boot.scr icon_android_hue.bmp bootlogo_android.bmp; do
    sudo cp "$TEMP_DIR/$file" "$SD_MOUNT/switchroot/android/"
  done
  sudo cp "$TEMP_DIR/$ZIP_FILE" "$SD_MOUNT/"
  if [ "$DOWNLOAD_GAPPS" = "yes" ] && [ -n "$GAPPS_FILENAME" ]; then
    sudo cp "$TEMP_DIR/$GAPPS_FILENAME" "$SD_MOUNT/"
  fi
  echo "[LineageOS]
l4t=1
boot_prefixes=switchroot/android/
id=SWANDR
icon=switchroot/android/icon_android_hue.bmp
logopath=switchroot/android/bootlogo_android.bmp
r2p_action=self
usb3_enable=1
emmc=1" | sudo tee "$SD_MOUNT/bootloader/ini/android.ini" > /dev/null
  sudo sync ) &
spinner $!
echo "Files copied successfully."

# Step 4: Unmount SD, Mount eMMC
echo "=== Step 4: Unmount SD and Mount eMMC ==="
sudo umount $SD_MOUNT
echo "SD card unmounted. Now mount your eMMC..."
echo "1. Unplug SD card USB from computer."
echo "2. In Hekate: 'Tools' > 'USB Tools' > 'Disable Read-Only' > 'eMMC RAW GPP'"
echo "3. In VMware: Ensure USB is passed through (VM > Removable Devices > Connect)."
read -p "Press Enter when eMMC is connected via Hekate UMS..."

echo "Detecting eMMC..."
COUNT=0
EMMC_DEV=""
echo -n "Scanning"
while [ -z "$EMMC_DEV" ] && [ $COUNT -lt $TIMEOUT ]; do
    NEW_DISKS=$(lsblk -o NAME,SIZE,LABEL,TYPE | grep disk | grep -v "sda")
    if [ -n "$NEW_DISKS" ]; then
        echo -e "\nDetected devices:"
        echo "$NEW_DISKS"
        read -p "Enter eMMC device (e.g., sdb) or 'retry' to wait: " EMMC_DEV
        if [ "$EMMC_DEV" = "retry" ]; then
            EMMC_DEV=""
            echo -n "Retrying"
        else
            EMMC_SIZE=$(lsblk -b -n -o SIZE /dev/$EMMC_DEV | head -n 1)
            EMMC_SIZE_GB=$(echo "scale=1; $EMMC_SIZE / 1024 / 1024 / 1024" | bc)
            echo "Selected: $EMMC_DEV ($EMMC_SIZE_GB GB)"
            if [ $(echo "$EMMC_SIZE_GB < 25 || $EMMC_SIZE_GB > 65" | bc) -eq 1 ]; then
                echo "Warning: Size ($EMMC_SIZE_GB GB) does not match typical eMMC (29GB or 58GB)!"
                read -p "Confirm this is your eMMC? (y/N): " CONFIRM_EMMC
                if [ "$CONFIRM_EMMC" != "y" ] && [ "$CONFIRM_EMMC" != "Y" ]; then
                    EMMC_DEV=""
                    echo "Retrying detection..."
                fi
            fi
            if [ -n "$EMMC_DEV" ] && [ -b "/dev/$EMMC_DEV" ]; then
                break
            else
                echo "Error: Invalid device '$EMMC_DEV'! Retrying..."
                EMMC_DEV=""
            fi
        fi
    fi
    echo -n "."
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ -z "$EMMC_DEV" ]; then
    echo -e "\nAuto-detection timed out! Current devices:"
    lsblk -o NAME,SIZE,LABEL,TYPE
    read -p "Enter eMMC device (e.g., sdb): " EMMC_DEV
    if [ ! -b "/dev/$EMMC_DEV" ]; then
        echo "Error: Invalid eMMC device '$EMMC_DEV'!"
        exit 1
    fi
fi

# Step 5: Erase, Repartition, and Flash eMMC
echo "=== Step 5: Erase, Repartition, and Flash eMMC ==="
echo "Selected: $EMMC_DEV ($EMMC_SIZE_GB GB) - Confirm this is your eMMC? (y/N)"
read -r CONFIRM
[ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && exit 1

echo "Last chance to abort! Proceed with erase, repartition, and flash? (y/N)"
read -r FINAL_CONFIRM
[ "$FINAL_CONFIRM" != "y" ] && [ "$FINAL_CONFIRM" != "Y" ] && exit 1

echo "Erasing eMMC..."
sudo sgdisk -Z /dev/$EMMC_DEV || {
    echo "Error: sgdisk -Z failed!"
    exit 1
}
echo "Partition table zapped successfully."

echo "Partitioning eMMC..."
sudo sgdisk /dev/$EMMC_DEV -o && sudo sgdisk /dev/$EMMC_DEV -g && \
sudo parted /dev/$EMMC_DEV mklabel gpt && \
sudo parted /dev/$EMMC_DEV mkpart boot 1MiB 65MiB && \
sudo parted /dev/$EMMC_DEV mkpart recovery 65MiB 129MiB && \
sudo parted /dev/$EMMC_DEV mkpart dtb 129MiB 130MiB && \
sudo parted /dev/$EMMC_DEV mkpart misc 130MiB 133MiB && \
sudo parted /dev/$EMMC_DEV mkpart cache 133MiB 193MiB && \
sudo parted /dev/$EMMC_DEV mkpart super 193MiB 6115MiB && \
sudo parted /dev/$EMMC_DEV mkpart userdata 6115MiB 100% || {
    echo "Error: Partition creation failed!"
    lsblk -o NAME,SIZE,LABEL,TYPE | grep "$EMMC_DEV"
    exit 1
}
echo "Partitions created. Syncing..."
sync
sleep 1
if [ -b "/dev/${EMMC_DEV}7" ]; then
    sudo mkfs.ext4 /dev/${EMMC_DEV}7 || {
        echo "Error: Formatting ${EMMC_DEV}7 failed!"
        exit 1
    }
    echo "Partitioning complete."
else
    echo "Error: Partition ${EMMC_DEV}7 not found!"
    lsblk -o NAME,SIZE,LABEL,TYPE | grep "$EMMC_DEV"
    exit 1
fi

echo "Flashing eMMC from local files..."
sudo dd if="$TEMP_DIR/boot.img" of=/dev/${EMMC_DEV}1 bs=32M status=progress
sudo dd if="$TEMP_DIR/recovery.img" of=/dev/${EMMC_DEV}2 bs=32M status=progress
sudo dd if="$TEMP_DIR/nx-plat.dtimg" of=/dev/${EMMC_DEV}3 bs=32M status=progress
sudo sync
echo "eMMC flashing complete!"

# Step 6: Cleanup Option
echo "=== Step 6: Cleanup ==="
echo "Files are stored in $TEMP_DIR."
read -p "Delete downloaded files or keep for backup? (d/k): " CLEANUP
if [ "$CLEANUP" = "d" ] || [ "$CLEANUP" = "D" ]; then
    sudo rm -rf "$TEMP_DIR"
    echo "Files deleted."
else
    echo "Files kept in $TEMP_DIR for backup."
fi

echo "=== Done! Unplug USB, Get back to Home, select More Configs, select Android while holding the Volume Up button! ==="
echo "Select Factory Reset, Format Data, Select Apply Update, Choose from Disk and flash the zip files."
