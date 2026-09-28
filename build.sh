#!/bin/bash
set -e
# Make sure BoxedOS dir is there
mkdir -p BoxedOS
#
WORK_DIR="BoxedOS"
IMG="$WORK_DIR/disk.img"
MNT="$WORK_DIR/esp_mnt"

# Parse command line arguments for the --steal flag
STEAL_CACHYOS=false
for arg in "$@"; do
    case $arg in
        --steal)
            STEAL_CACHYOS=true
            ;;
    esac
done

echo "[+] Building BoxD components..."
gcc -static boxd.c -o boxd -lpthread
crystal build --release box.cr -o box
crystal build --release networkd.cr -o networkd

echo "[+] Staging Initramfs payload..."
rm -rf initramfs_staging
mkdir -p initramfs_staging/{bin,sbin,proc,sys,dev,etc,root}

# 1. Copy the real Crystal binary as real init
cp boxd initramfs_staging/init
chmod +x initramfs_staging/init

# 2. Copy the other crystal BoxD components
cp box neededboot/bin/box
cp networkd neededboot/bin/networkd

# 3. Copy contents of ./neededboot into the root of initramfs if it exists
if [ -d "neededboot" ]; then
    echo "[+] Copying ./neededboot contents into initramfs root..."
    cp -r neededboot/. initramfs_staging/
fi

# 4. Copy contents of ./slapinroot into the root filesystem loaded at boot
if [ -d "slapinroot" ]; then
    echo "[+] Copying ./slapinroot contents into root filesystem..."
    cp -r slapinroot/. initramfs_staging/
fi

echo "[+] Packing cpio archive..."
cd initramfs_staging
find . -print0 | cpio --null -ov --format=newc > ../$WORK_DIR/initramfs.cpio
cd ..
rm -rf initramfs_staging

echo "[+] Creating 128MB UEFI FAT32 disk image..."
mkdir -p "$WORK_DIR"
rm -f "$IMG"
dd if=/dev/zero of="$IMG" bs=1M count=128
mkfs.fat -F32 "$IMG"

echo "[+] Mounting disk image and installing GRUB EFI..."
mkdir -p "$MNT"
sudo mount "$IMG" "$MNT"

# Install GRUB for UEFI directly onto the FAT image (removable mode places it at EFI/BOOT/BOOTX64.EFI)
sudo grub-install --target=x86_64-efi --efi-directory="$MNT" --boot-directory="$MNT/boot" --removable --no-nvram

# Determine kernel source based on flags
if [ "$STEAL_CACHYOS" = true ]; then
    echo "[+] Stealing CachyOS kernel from host..."
    KERNEL_SRC="/boot/vmlinuz-linux-cachyos"
    if [ ! -f "$KERNEL_SRC" ]; then
        echo "[!] Error: CachyOS kernel not found at $KERNEL_SRC"
        sudo umount "$MNT"
        rm -rf "$MNT"
        exit 1
    fi
else
    echo "[+] Using default custom NewKernel..."
    KERNEL_SRC="NewKernel"
    if [ ! -f "$KERNEL_SRC" ]; then
        echo "[!] Error: 'NewKernel' not found in project root. Did you forget to move or compile it?"
        sudo umount "$MNT"
        rm -rf "$MNT"
        exit 1
    fi
fi

echo "[+] Copying kernel ($KERNEL_SRC) and initramfs to disk image..."
sudo cp -L "$KERNEL_SRC" "$MNT/boot/vmlinuz"
sudo cp -L "$WORK_DIR/initramfs.cpio" "$MNT/boot/initramfs.cpio"

echo "[+] Writing GRUB configuration..."
sudo mkdir -p "$MNT/boot/grub"
sudo bash -c "cat << 'EOF' > '$MNT/boot/grub/grub.cfg'
set timeout=5
set default=0

menuentry \"BoxedOS (UEFI + BoxD + Custom Root)\" {
    linux /boot/vmlinuz quiet
    initrd /boot/initramfs.cpio
}
EOF"

sudo umount "$MNT"
rm -rf "$MNT"

echo "SUCCESS! UEFI disk image ready at '$IMG' using kernel: $KERNEL_SRC."
