qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 2048M \
    -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE_4M.fd \
    -drive file=BoxedOS/disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-pci,drive=hd0 \
    -netdev user,id=net0 \
    -device e1000,netdev=net0
