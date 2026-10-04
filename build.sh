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

echo "[+] Checking for kernel modules in slapinroot..."
if [ ! -d "slapinroot/lib/modules" ]; then
    # Look for either .tar.gz or uncompressed .tar
    ARCHIVE=""
    if [ -f "BoxDModules.tar.gz" ]; then
        ARCHIVE="BoxDModules.tar.gz"
    elif [ -f "BoxDModules.tar" ]; then
        ARCHIVE="BoxDModules.tar"
    fi

    if [ -n "$ARCHIVE" ]; then
        echo "[+] Found $ARCHIVE, extracting modules..."
        tar -xf "$ARCHIVE"
        
        # Handle directory structures gracefully
        mkdir -p slapinroot/lib
        if [ -d "BoxDModules/lib/modules" ]; then
            cp -r BoxDModules/lib/modules slapinroot/lib/
            rm -rf BoxDModules
        elif [ -d "lib/modules" ]; then
            cp -r lib/modules slapinroot/lib/
            rm -rf lib
        else
            echo "[!] Warning: Extracted structure unexpected, attempting direct move..."
            mv lib/modules slapinroot/lib/ 2>/dev/null || true
        fi
    else
        echo "[!] Error: Kernel modules not found at 'slapinroot/lib/modules' and archive is missing."
        echo "[!] Please download 'BoxDModules.tar.gz' from Google Drive and place it in this project folder:"
        echo "[!] https://drive.google.com/file/d/1uV118dbrWDvCm7_wlwjNoe5K174Ib80v/view"
        exit 1
    fi
fi

echo "[+] Building BoxD components..."
cd BoxdStuff/BoxD
gcc -static boxd.c -o boxd -lpthread
crystal build --release box.cr -o box
cd ..
cd NetworkD
crystal build --release networkd.cr -o network
cd ../
cd Tape
cd tape
crystal build --release tape.cr -o tape
cd ../
cd tapepack
crystal build --release tapepack.cr -o tapepack
cd ../../../
echo "[+] Staging binaries into slapinroot..."
#pwd # Kinda lowkey needed for debugging cuz I got confused w/ relative paths
mkdir -p slapinroot/bin slapinroot/usr/bin slapinroot/services

# Place boxd as the native rootfs init binary (PID 1)
cp BoxdStuff/BoxD/boxd slapinroot/init
chmod +x slapinroot/init

# Place box and networkd binaries
cp BoxdStuff/BoxD/box slapinroot/bin/box
cp BoxdStuff/NetworkD/networkd slapinroot/bin/networkd
chmod +x slapinroot/bin/box slapinroot/bin/networkd

# Place tape stuffs
cp BoxdStuff/Tape/tape/tape slapinroot/bin/tape
cp BoxdStuff/Tape/tapepack/tapepack slapinroot/bin/tapepack
chmod +x slapinroot/bin/tape slapinroot/bin/tapepack

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
