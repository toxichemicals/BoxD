qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -m 2048M \
    -drive if=pflash,format=raw,readonly=on,file=./OVMF_CODE_4M.fd \
    -drive file=BoxedOS/disk.img,format=raw 
