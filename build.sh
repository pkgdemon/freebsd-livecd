#!/bin/sh
# build.sh — assemble a FreeBSD live ISO with mkuzip rootfs + gunion overlay.
# Runs on FreeBSD (host or vmactions VM). Produces out/livecd.iso.

set -eu

: "${FREEBSD_VERSION:=15.0}"
: "${COMPRESS:=zstd}"
: "${LABEL:=LIVECD}"
ARCH=${ARCH:-amd64}

ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$ROOT/work
OUT=$ROOT/out
DIST=$ROOT/distfiles

MIRROR="https://download.freebsd.org/ftp/releases/${ARCH}/${FREEBSD_VERSION}-RELEASE"

mkdir -p "$WORK" "$OUT" "$DIST"

# Clean any prior partial build (but keep distfiles cached)
rm -rf "$WORK"/* "$OUT"/*

echo "==> build: FreeBSD $FREEBSD_VERSION ($ARCH), compress=$COMPRESS"

#
# 1. fetch base.txz + kernel.txz
#
for f in base.txz kernel.txz; do
    if [ ! -f "$DIST/$f" ]; then
        echo "==> downloading $f"
        fetch -o "$DIST/$f" "$MIRROR/$f"
    fi
done

#
# 2. extract into rootfs staging dir
#
echo "==> extracting base+kernel"
mkdir -p "$WORK/rootfs"
tar -xJf "$DIST/base.txz"   -C "$WORK/rootfs"
tar -xJf "$DIST/kernel.txz" -C "$WORK/rootfs"

#
# 3. install packages from pkglist.txt (skipped if empty/comments-only)
#
PKGS=$(grep -v '^[[:space:]]*#' "$ROOT/pkglist.txt" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
if [ -n "$PKGS" ]; then
    echo "==> installing packages:"
    echo "$PKGS" | sed 's/^/    /'
    cp /etc/resolv.conf "$WORK/rootfs/etc/resolv.conf"
    mount -t devfs devfs "$WORK/rootfs/dev"
    cleanup_chroot() {
        umount -f "$WORK/rootfs/dev" 2>/dev/null || true
        rm -f "$WORK/rootfs/etc/resolv.conf"
    }
    trap cleanup_chroot EXIT INT TERM
    chroot "$WORK/rootfs" env ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes pkg bootstrap -f
    # shellcheck disable=SC2086
    chroot "$WORK/rootfs" env ASSUME_ALWAYS_YES=yes IGNORE_OSVERSION=yes pkg install -y $PKGS
    cleanup_chroot
    trap - EXIT INT TERM
else
    echo "==> pkglist.txt empty; skipping pkg install"
fi

#
# 4. apply local overlays (etc/rc.conf, etc/rc.local, etc/motd.template, ...)
#
if [ -d "$ROOT/overlays" ]; then
    echo "==> applying overlays"
    cp -aR "$ROOT/overlays/." "$WORK/rootfs/"
fi

# rc.local needs to be executable
[ -f "$WORK/rootfs/etc/rc.local" ] && chmod +x "$WORK/rootfs/etc/rc.local"

#
# 5. write a minimal /etc/fstab — root is mounted by reboot -r, no entries needed
#
cat > "$WORK/rootfs/etc/fstab" <<'EOF'
# Live system: root is the gunion(8) overlay device, mounted by reboot -r
# from /boot/loader.conf's vfs.root.mountfrom kenv. No fstab entries required.
EOF

#
# 6. record uncompressed rootfs size; the init script reads this to size the
#    swap-md upper exactly to match the lower
#
ROOTFS_BYTES=$(du -sk "$WORK/rootfs" | awk '{print $1*1024}')
echo "$ROOTFS_BYTES" > "$WORK/rootfs.bytes"
echo "==> rootfs uncompressed = $ROOTFS_BYTES bytes ($((ROOTFS_BYTES / 1024 / 1024)) MiB)"

#
# 7. makefs UFS image of the rootfs, then mkuzip it
#
echo "==> makefs ffs"
makefs -t ffs -o version=2,label=ROOTFS \
    "$WORK/rootfs.ufs" "$WORK/rootfs"

mkdir -p "$WORK/cdroot/boot"
case "$COMPRESS" in
    zstd) MKUZIP_FLAGS="-A zstd -C 19 -d -s 262144" ;;
    zlib) MKUZIP_FLAGS="-d -s 65536" ;;
    *)    echo "ERROR: unknown COMPRESS=$COMPRESS"; exit 1 ;;
esac
echo "==> mkuzip $MKUZIP_FLAGS"
mkuzip $MKUZIP_FLAGS -j "$(sysctl -n hw.ncpu)" \
    -o "$WORK/cdroot/boot/rootfs.uzip" "$WORK/rootfs.ufs"
ls -lh "$WORK/cdroot/boot/rootfs.uzip"

#
# 8. build the mfs_root: tiny UFS containing /rescue + /init.sh + size sidecar
#
echo "==> building mfsroot"
mkdir -p "$WORK/ramdisk/rescue" "$WORK/ramdisk/dev" \
         "$WORK/ramdisk/etc"    "$WORK/ramdisk/sbin" \
         "$WORK/ramdisk/sysroot"
cp -aR "$WORK/rootfs/rescue/." "$WORK/ramdisk/rescue/"

# /sbin/init -> /rescue/init (real FreeBSD init binary; reads init_script kenv)
ln -sf /rescue/init "$WORK/ramdisk/sbin/init"

# our pivot script + size sidecar that init.sh reads
cp "$ROOT/ramdisk/init.sh" "$WORK/ramdisk/init.sh"
chmod +x "$WORK/ramdisk/init.sh"
echo "$ROOTFS_BYTES" > "$WORK/ramdisk/etc/rootfs.bytes"

makefs -t ffs -o version=2,label=MFSROOT \
    "$WORK/mfsroot.ufs" "$WORK/ramdisk"
gzip -9 -f "$WORK/mfsroot.ufs"
mv "$WORK/mfsroot.ufs.gz" "$WORK/cdroot/boot/mfsroot"
ls -lh "$WORK/cdroot/boot/mfsroot"

#
# 9. stage kernel + modules + loader binaries on the cd9660 carrier.
#    Copy the entire /boot tree from the rootfs — the Lua-based loader
#    needs /boot/lua/, /boot/defaults/, /boot/device.hints, fonts, etc.
#    Then drop our loader.conf on top.
#
echo "==> staging /boot"
cp -aR "$WORK/rootfs/boot/." "$WORK/cdroot/boot/"
# Our loader.conf overrides /boot/defaults/loader.conf knobs as needed
cp "$ROOT/boot/loader.conf" "$WORK/cdroot/boot/loader.conf"

#
# 10. EFI System Partition image (BOOTX64.EFI inside) AND a copy on the
#     cd9660 root, so OVMF can find the bootloader either through the
#     El Torito EFI entry or by reading the cd9660 directly.
#     UEFI spec wants FAT16+ for ESP; use fat_type=16 with a 32 MiB image.
#
echo "==> building EFI System Partition + cd9660 EFI overlay"
ESP="$WORK/efi.img"
ESPROOT="$WORK/efi-staging"
mkdir -p "$ESPROOT/EFI/BOOT"

# Pick a loader.efi: prefer loader_lua.efi (modern), fall back to loader.efi.
if [ -f "$WORK/rootfs/boot/loader_lua.efi" ]; then
    EFI_LOADER="$WORK/rootfs/boot/loader_lua.efi"
elif [ -f "$WORK/rootfs/boot/loader.efi" ]; then
    EFI_LOADER="$WORK/rootfs/boot/loader.efi"
else
    echo "ERROR: no loader.efi found in base.txz boot/"
    exit 1
fi
echo "==> EFI loader: $EFI_LOADER"

cp "$EFI_LOADER" "$ESPROOT/EFI/BOOT/BOOTX64.EFI"

# Build the El Torito ESP image (FAT16, 32 MiB)
makefs -t msdos -s 32m -o fat_type=16,sectors_per_cluster=1 \
    "$ESP" "$ESPROOT"

# Also stage /EFI/BOOT/BOOTX64.EFI directly on the cd9660 — UEFI firmwares
# that read ISO9660 (incl. OVMF) will find it via the default boot path.
mkdir -p "$WORK/cdroot/EFI/BOOT"
cp "$EFI_LOADER" "$WORK/cdroot/EFI/BOOT/BOOTX64.EFI"

#
# 11. final cd9660 image: hybrid BIOS + UEFI El Torito
#
echo "==> building ISO"
BOOTABLE_ARGS=""
if [ -f "$WORK/cdroot/boot/cdboot" ]; then
    BOOTABLE_ARGS="-o bootimage=i386;$WORK/cdroot/boot/cdboot -o no-emul-boot"
fi
BOOTABLE_ARGS="$BOOTABLE_ARGS -o bootimage=i386;$ESP -o no-emul-boot -o platformid=efi"

# shellcheck disable=SC2086
makefs -D -N "$WORK/rootfs/etc" -t cd9660 \
    -o rockridge -o label="$LABEL" \
    $BOOTABLE_ARGS \
    "$OUT/livecd.iso" "$WORK/cdroot"

ls -lh "$OUT/livecd.iso"
sha256 "$OUT/livecd.iso" 2>/dev/null || sha256sum "$OUT/livecd.iso"
echo "==> DONE"
