#!/bin/bash
set -e

mkdir -p BoxedOS
WORK_DIR="BoxedOS"
IMG="$WORK_DIR/disk.img"
MNT_ESP="$WORK_DIR/esp_mnt"
MNT_ROOT="$WORK_DIR/root_mnt"

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

echo "[+] Staging binaries into slapinroot..."
mkdir -p slapinroot/bin slapinroot/usr/bin slapinroot/services

# Place boxd as the native rootfs init binary (PID 1)
cp boxd slapinroot/init
chmod +x slapinroot/init

# Place box and networkd binaries
cp box slapinroot/usr/bin/box
cp networkd slapinroot/bin/networkd
chmod +x slapinroot/usr/bin/box slapinroot/bin/networkd

# Copy neededboot contents if they exist
if [ -d "neededboot" ]; then
    cp -r neededboot/. slapinroot/
fi

echo "[+] Creating 4GB partitioned disk image..."
rm -f "$IMG"
# 4GB to comfortably fit 2.3G slapinroot plus ESP
dd if=/dev/zero of="$IMG" bs=1M count=4096

echo "[+] Setting up GPT partition table..."
parted -s "$IMG" mklabel gpt
parted -s "$IMG" mkpart ESP fat32 1MiB 512MiB
parted -s "$IMG" mkpart primary ext4 512MiB 100%
parted -s "$IMG" set 1 esp on

echo "[+] Setting up loop device..."
LOOPDEV=$(sudo losetup --find --show -P "$IMG")

cleanup() {
    set +e
    sudo umount "$MNT_ESP" 2>/dev/null || true
    sudo umount "$MNT_ROOT" 2>/dev/null || true
    sudo losetup -d "$LOOPDEV" 2>/dev/null || true
}
trap cleanup EXIT

echo "[+] Formatting partitions..."
sudo mkfs.fat -F32 "${LOOPDEV}p1"
sudo mkfs.ext4 -F "${LOOPDEV}p2"

echo "[+] Mounting partitions..."
mkdir -p "$MNT_ESP" "$MNT_ROOT"
sudo mount "${LOOPDEV}p1" "$MNT_ESP"
sudo mount "${LOOPDEV}p2" "$MNT_ROOT"

echo "[+] Copying slapinroot directly into root partition..."
sudo cp -a slapinroot/. "$MNT_ROOT/"

echo "[+] Installing GRUB EFI on ESP..."
sudo grub-install --target=x86_64-efi --efi-directory="$MNT_ESP" --boot-directory="$MNT_ESP/boot" --removable --no-nvram

# Determine kernel source based on flags
if [ "$STEAL_CACHYOS" = true ]; then
    echo "[+] Stealing CachyOS kernel from host..."
    KERNEL_SRC="/boot/vmlinuz-linux-cachyos"
    if [ ! -f "$KERNEL_SRC" ]; then
        echo "[!] Error: CachyOS kernel not found at $KERNEL_SRC"
        exit 1
    fi
else
    echo "[+] Using default custom NewKernel..."
    KERNEL_SRC="NewKernel"
    if [ ! -f "$KERNEL_SRC" ]; then
        echo "[!] Error: 'NewKernel' not found in project root."
        exit 1
    fi
fi

echo "[+] Copying kernel to ESP..."
sudo mkdir -p "$MNT_ESP/boot"
sudo cp -L "$KERNEL_SRC" "$MNT_ESP/boot/vmlinuz"

echo "[+] Retrieving root filesystem UUID..."
ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOPDEV}p2")
echo "[+] Root filesystem UUID: $ROOT_UUID"

echo "[+] Writing GRUB configuration..."
sudo mkdir -p "$MNT_ESP/boot/grub"
sudo bash -c "cat << 'EOF' > '$MNT_ESP/boot/grub/grub.cfg'
set timeout=5
set default=0

menuentry \"BoxedOS (UEFI + BoxD + Native RootFS)\" {
    linux /boot/vmlinuz root=/dev/vda2 init=/init rw quiet
}
EOF"

echo "[+] Unmounting and cleaning up..."
sudo umount "$MNT_ESP"
sudo umount "$MNT_ROOT"
sudo losetup -d "$LOOPDEV"
trap - EXIT

echo "SUCCESS! Partitioned UEFI disk image ready at '$IMG'."
