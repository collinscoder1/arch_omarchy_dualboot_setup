# Arch Linux Dual-Boot Setup Script

A robust, user-friendly bash script to prepare your disk for an Arch Linux installation.
Designed to handle **Disk Encryption (LUKS)**, **Dual-Booting (Windows)**, and **Safe Partition Management**.

This script handles the **partitioning and mounting** phase. After running this, various partitions will be mounted at `/mnt`, ready for `archinstall` or a manual `pacstrap`.

## Features

- **🚀 Interactive TUI**: User-friendly menus using `whiptail`.
- **🔒 Optional Encryption**: Choose between LUKS encryption or plain Btrfs.
- **💾 Dual-Boot Safe**: Detects Windows EFI partitions and avoids conflicts by creating a separate `ARCH_EFI`.
- **🧠 Intelligent Partitioning**:
  - **Auto**: Automatically finds the largest free space and partitions it (1GB EFI + Rest Root).
  - **Custom**: Specify simple sizes (e.g. "50G") without calculating start/end sectors.
  - **Safe**: Only offers to wipe the disk if it is truly empty.
- **🛡️ Graceful Exit**: Cleanly aborts if you press Cancel, ensuring no half-broken state.
- **⚙️ NVMe & SATA Support**: Automatically handles `/dev/nvme0n1pX` vs `/dev/sdaX` naming.

## Prerequisites

The script relies on standard Arch ISO tools:
- `whiptail` (libnewt)
- `parted`
- `lsblk`
- `cryptsetup`
- `mkfs.btrfs`

## Usage

### ⚡ Quick Start (One-Liner)
Run the following command in your Arch ISO terminal (requires internet):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/collinscoder1/arch_omarchy_dualboot_setup/main/arch_omarchy_dualboot_setup.sh)"
```

### Manual Method
1. **Boot into Arch ISO**.
2. **Download or Clone** this script.
3. Make it executable:
   ```bash
   chmod +x arch_omarchy_dualboot_setup.sh
   ```
4. Run as root:
   ```bash
   ./arch_omarchy_dualboot_setup.sh
   ```
5. Follow the on-screen instructions.
6. **After completion**, run `archinstall`:
   ```bash
   archinstall --mount-point /mnt
   ```
   > **⚠️ IMPORTANT**: inside `archinstall`, **DO NOT** modify "Disk configuration" or "Mount points". The script has already done this for you. Just select your packages, user, and install.

## License

MIT / Public Domain
