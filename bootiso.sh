#!/bin/bash
set -e

ISO_DIR="iso_build"
OUTPUT_ISO="BoxedOS.iso"
KERNEL_SRC="BoxedOS/boot/vmlinuz"
INITRAMFS_SRC="BoxedOS/initramfs.cpio"

echo "[*] Preparing ISO staging directory..."
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/grub"

# 1. Copy Kernel and Initramfs
if [ ! -f "$KERNEL_SRC" ]; then
    echo "[!] Error: Kernel not found at $KERNEL_SRC."
    exit 1
fi

if [ ! -f "$INITRAMFS_SRC" ]; then
    echo "[!] Error: Initramfs not found at $INITRAMFS_SRC. Run build.sh first!"
    exit 1
fi

cp "$KERNEL_SRC" "$ISO_DIR/boot/bzImage"
cp "$INITRAMFS_SRC" "$ISO_DIR/boot/initramfs.cpio"

echo "[*] Writing GRUB configuration..."
cat << 'EOF' > "$ISO_DIR/boot/grub/grub.cfg"
set timeout=3
set default=0

menuentry "BoxedOS (Custom Linux Init)" {
    linux /boot/bzImage console=tty1 console=ttyS0 quiet
    initrd /boot/initramfs.cpio
}
EOF

echo "[*] Generating hybrid bootable ISO..."
grub-mkrescue -o "$OUTPUT_ISO" "$ISO_DIR"

echo "[+] Success! ISO generated: $OUTPUT_ISO"
echo "[+] You can now copy $OUTPUT_ISO to your Ventoy USB drive or flash it directly using dd."
