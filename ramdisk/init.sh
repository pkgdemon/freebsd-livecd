#!/rescue/sh
# /init.sh — runs as a child of /sbin/init via init_script kenv.
#
# This script lives at the root of the cd9660 ISO. The kernel mounts
# cd9660 as /, init runs from /sbin/init (FreeBSD's real init binary from
# base.txz), reads init_script=/init.sh kenv, forks, and execs us.
#
# We set up a gunion overlay (read-only uzip lower + swap-backed writable
# upper) at /sysroot, then write init_chroot=/sysroot kenv and exit. After
# we exit, init proceeds to read init_chroot at init.c:333 and chroots
# into /sysroot before continuing normal multi-user boot. cd9660 stays
# mounted as the kernel's actual root; userland sees /sysroot as /.
#
# Memory cost: ~50 MB (only decompressed pages of accessed uzip data).

set -eu
PATH=/rescue
export PATH

echo "==> livecd init.sh: starting"

# Defensive module loads (also requested in /boot/loader.conf, but be safe
# in case someone built a kernel without the loader.conf entries).
kldload geom_uzip 2>/dev/null || true
kldload geom_union 2>/dev/null || true

# Vnode-mount the compressed rootfs from the cd9660. /rootfs.uzip is at
# the root of the cd9660 (placed there by build.sh). geom_uzip auto-tastes
# /dev/md0 and produces /dev/md0.uzip.
echo "==> attaching /rootfs.uzip as md0"
mdconfig -a -t vnode -o readonly -f /rootfs.uzip -u 0

# Wait for the uzip taste to complete
echo "==> waiting for /dev/md0.uzip"
i=0
while [ ! -e /dev/md0.uzip ]; do
    sleep 1
    i=$((i+1))
    if [ "$i" -gt 30 ]; then
        echo "ERROR: /dev/md0.uzip not present after 30s"
        ls -la /dev/md* 2>/dev/null || true
        halt -p
    fi
done

# Read the uncompressed rootfs size sidecar; size the swap-md upper to match.
# Round up to the nearest MB — the byte-suffix form trips EDOM in mdcreate_swap
# unless the byte count is sectorsize-aligned (4096 on modern md), which raw
# `du -sk * 1024` typically isn't.
ROOTFS_BYTES=$(cat /rootfs.bytes)
ROOTFS_MB=$(( (ROOTFS_BYTES + 1048575) / 1048576 ))
echo "==> creating swap-backed upper md1 (size=${ROOTFS_MB} MB, rounded from ${ROOTFS_BYTES} bytes)"
mdconfig -a -t swap -s "${ROOTFS_MB}m" -u 1

# Compose the overlay. md0.uzip = read-only lower, md1 = writable upper.
# Using `geom union create` rather than `gunion create` because /rescue
# ships /rescue/geom (the multi-class GEOM tool) but not a `gunion` alias.
echo "==> creating gunion overlay"
geom union create md1 md0.uzip
UNION_DEV=/dev/md1-md0.uzip.union
if [ ! -e "$UNION_DEV" ]; then
    echo "ERROR: gunion device $UNION_DEV not present after create"
    halt -p
fi

# Mount the union at /sysroot. /sysroot exists as an empty directory on
# the cd9660 (build.sh creates it) — we can't mkdir it here because cd9660
# is read-only at runtime.
echo "==> mounting union at /sysroot"
mount "$UNION_DEV" /sysroot
mount -t devfs devfs /sysroot/dev

# Tell init to chroot into /sysroot after we exit. init.c reads init_chroot
# kenv at line 333, which is AFTER the script runs (line 326-331), so a
# kenv set here will be honored.
echo "==> setting init_chroot=/sysroot"
kenv init_chroot=/sysroot

# Unset init_script so init doesn't try to re-run us after the chroot.
# (init only reads init_script once at startup, but unset for cleanliness.)
kenv -u init_script 2>/dev/null || true
kenv -u init_shell  2>/dev/null || true

echo "==> exiting; init will chroot and continue multi-user boot"
exit 0
