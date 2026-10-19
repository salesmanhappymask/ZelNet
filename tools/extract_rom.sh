#!/bin/sh
set -e
if [ -z "$1" ]; then
    echo "usage: tools/extract_rom.sh path/to/ComputerCraft1.63.jar"
    exit 1
fi
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
unzip -q -o "$1" 'assets/computercraft/lua/*' -d "$tmp"
rm -rf "$root/sim/rom"
mkdir -p "$root/sim/rom"
cp -r "$tmp/assets/computercraft/lua/bios.lua" "$tmp/assets/computercraft/lua/rom" "$root/sim/rom/"
rm -rf "$tmp"
echo "ROM extracted to $root/sim/rom"
