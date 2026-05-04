#!/bin/sh
# build.sh — assemble a FreeBSD live ISO using the init_chroot architecture:
#   cd9660 = kernel root; vnode-mounted rootfs.uzip with gunion overlay;
#   pivot via init_chroot kenv (no preload, no mfsroot, no reboot -r).
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
# 4. trim rootfs of things not needed at runtime
#
echo "==> slimming rootfs"
rm -rf \
    "$WORK/rootfs/usr/share/man" \
    "$WORK/rootfs/usr/share/doc" \
    "$WORK/rootfs/usr/share/info" \
    "$WORK/rootfs/usr/share/locale" \
    "$WORK/rootfs/usr/share/games" \
    "$WORK/rootfs/usr/share/examples" \
    "$WORK/rootfs/usr/share/openssl" \
    "$WORK/rootfs/usr/share/dict" \
    "$WORK/rootfs/usr/share/calendar" \
    "$WORK/rootfs/usr/include" \
    "$WORK/rootfs/usr/tests" \
    "$WORK/rootfs/usr/lib/debug" \
    "$WORK/rootfs/usr/libdata/lint" \
    "$WORK/rootfs/var/db/etcupdate"
find "$WORK/rootfs/boot/kernel" -name '*.symbols' -delete 2>/dev/null || true

#
# 5. apply local overlays (etc/rc.conf, etc/rc.local, ...)
#
if [ -d "$ROOT/overlays" ]; then
    echo "==> applying overlays"
    cp -aR "$ROOT/overlays/." "$WORK/rootfs/"
fi

# rc.local needs to be executable
[ -f "$WORK/rootfs/etc/rc.local" ] && chmod +x "$WORK/rootfs/etc/rc.local"

#
# 6. minimal /etc/fstab; root mounted by gunion at boot, no entries needed
#
cat > "$WORK/rootfs/etc/fstab" <<'EOF'
# Live system: root is the gunion overlay device (mounted at /sysroot in
# the ramdisk-style init phase, then exposed as / via init_chroot).
EOF

#
# 7. record uncompressed size, makefs UFS, mkuzip
#
ROOTFS_BYTES=$(du -sk "$WORK/rootfs" | awk '{print $1*1024}')
echo "$ROOTFS_BYTES" > "$WORK/rootfs.bytes"
echo "==> rootfs uncompressed = $ROOTFS_BYTES bytes ($((ROOTFS_BYTES / 1024 / 1024)) MiB)"

echo "==> makefs ffs"
makefs -t ffs -o version=2,label=ROOTFS \
    "$WORK/rootfs.ufs" "$WORK/rootfs"

mkdir -p "$WORK/cdroot"
case "$COMPRESS" in
    zstd) MKUZIP_FLAGS="-A zstd -C 19 -d -s 262144" ;;
    zlib) MKUZIP_FLAGS="-d -s 65536" ;;
    *)    echo "ERROR: unknown COMPRESS=$COMPRESS"; exit 1 ;;
esac
echo "==> mkuzip $MKUZIP_FLAGS"
mkuzip $MKUZIP_FLAGS -j "$(sysctl -n hw.ncpu)" \
    -o "$WORK/cdroot/rootfs.uzip" "$WORK/rootfs.ufs"

# size sidecar that init.sh reads to size the swap-md upper
cp "$WORK/rootfs.bytes" "$WORK/cdroot/rootfs.bytes"

# pivot script — lives at cd9660 root since init runs /init.sh
cp "$ROOT/ramdisk/init.sh" "$WORK/cdroot/init.sh"
chmod +x "$WORK/cdroot/init.sh"

# pre-create /sysroot as an empty mountpoint on the cd9660; init.sh can't
# mkdir it at boot because cd9660 is read-only at runtime
mkdir -p "$WORK/cdroot/sysroot"

ls -lh "$WORK/cdroot/rootfs.uzip"

#
# 8. stage /boot from the rootfs onto the cd9660, then drop our loader.conf
#
echo "==> staging /boot"
cp -aR "$WORK/rootfs/boot" "$WORK/cdroot/"
cp "$ROOT/boot/loader.conf" "$WORK/cdroot/boot/loader.conf"

#
# 9. EFI System Partition (FAT16, /EFI/BOOT/BOOTX64.EFI inside) and a copy
#    of the EFI loader at the cd9660 root for OVMF's ISO9660 discovery.
#
echo "==> building EFI System Partition"
ESP="$WORK/efi.img"
ESPROOT="$WORK/efi-staging"
mkdir -p "$ESPROOT/EFI/BOOT"
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
makefs -t msdos -s 32m -o fat_type=16,sectors_per_cluster=1 \
    "$ESP" "$ESPROOT"
mkdir -p "$WORK/cdroot/EFI/BOOT"
cp "$EFI_LOADER" "$WORK/cdroot/EFI/BOOT/BOOTX64.EFI"

#
# 10. final cd9660 (hybrid BIOS + UEFI El Torito)
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
