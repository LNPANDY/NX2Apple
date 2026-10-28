#!/bin/bash
# Copy a game's files to its iPhone app's Documents/romfs.img once, so later installs built with DM_COPY_ROMFS=NO skip them (see docs/development.md, Quick reinstalls).
# The files go as one RomFS image (dm/tools/romfs_image.py), packed next to the RomFS folder on first use: one file copies at full speed, where a folder of a few hundred
# thousand files ran the phone's file service out of open files (Tears of the Kingdom: 304,000). main.m only takes a complete image, so a copy cut off halfway is never used.
# Usage: push_romfs.sh <device UDID> <bundle ID> <game>_build/xcode/Gen/resources.env [--repack]
#    or: push_romfs.sh <device UDID> <bundle ID> <RomFS.img>   (the image build_ipa_from_nsp.py --romfs separate prints: <game>_build/extract/<version>/RomFS.img)
# A build made with DM_COPY_ROMFS=NO carries the identity of its image (romfs.id); the app uses only a Documents/romfs.img with that identity, so push again whenever the game or its version changed.
# Run it while the app (any build with that bundle ID) is installed. Rerun after a failure.
set -eu
[ "$#" = 3 ] || { [ "$#" = 4 ] && [ "$4" = --repack ]; } || { echo "usage: $0 <device UDID> <bundle ID> <resources.env> [--repack]" >&2; exit 1; }
dev=$1 id=$2
case "$3" in *.env) source "$3";; *) DM_RESOURCE_ROMFS=$3; DM_RESOURCE_MARKER=;; esac
if [ -f "$DM_RESOURCE_ROMFS" ]; then img=$DM_RESOURCE_ROMFS
else
    img=${DM_RESOURCE_ROMFS%/}.img
    repack=${4:-}; set -- "$DM_RESOURCE_ROMFS" "$img"
    [ "$repack" = --repack ] || set -- --reuse "$@"
    python3 -I "$(dirname "$0")/../dm/tools/romfs_image.py" "$@"
fi
python3 -I "$(dirname "$0")/../dm/tools/romfs.py" "$img" "${DM_RESOURCE_MARKER:-}"
echo "identity: $(python3 -I "$(dirname "$0")/../dm/tools/romfs_image.py" --identity "$img")"
xcrun devicectl device copy to --device "$dev" --domain-type appDataContainer --domain-identifier "$id" --source "$img" --destination Documents/romfs.img -q
echo "game files on the phone: $id"
