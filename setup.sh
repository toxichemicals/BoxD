#!/usr/bin/env bash

varurl='https://drive.usercontent.google.com/download?id=1uV118dbrWDvCm7_wlwjNoe5K174Ib80v&export=download&authuser=0&confirm=t&uuid=4aebb446-6549-4e5b-aa26-c3383fa6d0a6&at=AMrWOn2A_9VrQqCf-bgmkUBfHA8Q%3A1791116325640'
varout='BoxDModules.tar.gz'

if [ -f "$varout" ]; then
    echo "[+] Kernel modules already present, skipping download and building"
    bash build.sh
    echo "welcome to boxd os"
    bash qemu.sh
    exit 0
fi

echo "[+] Downloading kernel modules..."
curl -L --fail --progress-bar "$varurl" -o "$varout"

if [ $? -eq 0 ]; then
    echo "[+] Downloaded: $varout"
else
    echo "[-] Download failed"
    exit 1
fi

