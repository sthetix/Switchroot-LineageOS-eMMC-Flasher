# Switchroot-LineageOS-eMMC-Flasher

<div align="center">
  <a href="https://github.com/sthetix/NX-LOS-eMMC-Flasher">
    <img src="https://github.com/sthetix/NX-LOS-eMMC-Flasher/blob/main/title.png" alt="NX-LOS-eMMC-Flasher Logo" width="50%">
  </a>
</div>

A shell script to automate downloading and flashing the latest **LineageOS** and **MindTheGapps (ARM64)** to your Nintendo Switch’s eMMC. This script runs on Linux terminal, wipes the eMMC, repartitions it, and sets up everything you need to boot LineageOS.

---

![Warning](https://img.shields.io/badge/⚠️-WARNING-red)  
**⚠️ THIS SCRIPT WILL WIPE YOUR ENTIRE EMMC! ⚠️**  
**PLEASE BACK UP YOUR NAND BEFORE PROCEEDING!**  
If you do not back up your NAND, you will **lose access to the Nintendo Switch Horizon OS (HOS)** and will **not be able to restore it** without a backup.  
Use this script **AT YOUR OWN RISK**. We are not responsible for any data loss or damage to your device.

## Features
- Downloads the latest LineageOS build for Switch (Tablet or TV variant).
- Optionally fetches the matching MindTheGapps ARM64 package.
- Copies files to an SD card via Hekate UMS.
- Checks available SD card space before copying files.
- Supports a custom temporary download directory.
- Wipes, repartitions, and flashes the eMMC with a custom partition layout.
- Simple CLI interface with a spinner for background tasks.

## Requirements
- **Linux environment** (e.g., Ubuntu in VMware).
- **Hekate** installed on your Switch (for USB Mass Storage mode).
- **SD card** (FAT32 formatted).
- **Internet connection**.
- Root privileges (`sudo`).

## Dependencies
The script auto-installs these if missing:
- `curl`
- `jq`
- `sgdisk`
- `parted`
- `sha256sum`

## Usage
1. **Download the Script**:
   - Clone this repo or download `flash_lineageos.sh` from the [Releases page](https://github.com/sthetix/NX-LOS-eMMC-Flasher/releases).
   ```bash
   git clone https://github.com/sthetix/NX-LOS-eMMC-Flasher.git
   cd NX-LOS-eMMC-Flasher
   ```
2. **Make it Executable**:
   Important: You must set execute permissions before running the script.
   ```bash
   chmod +x flash_lineageos.sh
   ```
3. **Run the Script**:
   ```bash
   ./flash_lineageos.sh
   ```
   To use a custom temporary download directory:
   ```bash
   ./flash_lineageos.sh --tempdir /path/to/temp
   ```
   Or:
   ```bash
   NX_LOS_TEMP_DIR=/path/to/temp ./flash_lineageos.sh
   ```
4. **Follow Prompts**:
   - Choose Tablet (1) or TV (2) variant.
   - Decide if you want MindTheGapps (ARM64) (y/N).
   - Mount your SD card and eMMC via Hekate UMS when prompted.
   - Confirm eMMC wipe and flash.

## Post-Flash
- Unplug USB, return to Hekate Home.
- Go to More Configs, select Android while holding Volume Up.
- Perform a Factory Reset, Format Data, then Apply Update from the SD card to flash the ZIPs.

## Script Flow
- **Step 1: Selection**  
  Pick your device type and MindTheGapps option.
  
- **Step 2: Downloads**  
  Fetches LineageOS files with SHA256 verification.
  
- **Step 3: SD Card Prep**  
  Copies files to SD card via Hekate UMS.
  
- **Step 4: eMMC Mount**  
  Unmounts SD, mounts eMMC via Hekate UMS.
  
- **Step 5: Flash eMMC**  
  Wipes, repartitions, and flashes eMMC.
  
- **Step 6: Cleanup**  
  Option to delete or keep temp files.

## Partition Layout
| Partition | Start   | End     | Purpose            |
|-----------|---------|---------|--------------------|
| boot      | 1 MiB   | 65 MiB  | Bootloader         |
| recovery   | 65 MiB  | 129 MiB | Recovery           |
| dtb       | 129 MiB | 130 MiB | Device Tree        |
| misc      | 130 MiB | 133 MiB | Misc Data          |
| cache     | 133 MiB | 193 MiB | Cache              |
| super     | 193 MiB | 6115 MiB| System+Vendor      |
| userdata  | 6115 MiB| 100%    | User Data          |

> `userdata` is formatted as ext4.

## Troubleshooting
- **Permission Denied**: Ensure you ran `chmod +x flash_lineageos.sh` before executing.
- **API Errors**: Check internet or LineageOS/MindTheGapps servers.
- **Mount Issues**: Ensure Hekate UMS is active and USB is passed through in VMware.
- **Not Enough SD Space**: Free up space or use a larger SD card before rerunning.
- **File Missing**: Verify downloads completed in the temp directory printed by the script.

## Contributing
Feel free to fork, tweak, and submit pull requests! Report bugs or suggest features via Issues.

## License
This project is under the MIT License (LICENSE).
