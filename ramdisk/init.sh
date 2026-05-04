#!/rescue/sh
# /init.sh — runs as a child of /rescue/init (via init_script kenv).
#
# When the kernel boots, /sbin/init (real FreeBSD init binary, symlinked
# to /rescue/init in our mfsroot) reads the init_script kenv, forks, and
# execs this script via /rescue/sh. We perform the gunion overlay setup
# and call reboot -r, which signals init via SIGEMT to do the proper
# two-phase reroot.

set -eu
PATH=/rescue
export PATH

echo "==> livecd init.sh: starting"

# Defensive module loads (also requested in /boot/loader.conf, but be safe
# in case someone built a kernel without the loader.conf entries).
kldload geom_uzip 2>/dev/null || true
kldload geom_union 2>/dev/null || true

# The loader preloaded /boot/rootfs.uzip as md1 (md_image type). The kernel
# created the md device at boot; geom_uzip's taste hook should have produced
# /dev/md1.uzip already. Tasting is asynchronous, so loop briefly.
echo "==> waiting for /dev/md1.uzip"
i=0
while [ ! -e /dev/md1.uzip ]; do
    sleep 1
    i=$((i+1))
    if [ "$i" -gt 30 ]; then
        echo "ERROR: /dev/md1.uzip not present after 30s"
        echo "       md devices present:"
        ls -la /dev/md* 2>/dev/null || true
        echo "       halting."
        halt -p
    fi
done

# Size the swap-backed upper exactly to match the lower. The build wrote
# the uncompressed rootfs size (in bytes) to /etc/rootfs.bytes.
ROOTFS_BYTES=$(cat /etc/rootfs.bytes)
echo "==> creating swap-backed upper md2 (size=${ROOTFS_BYTES} bytes)"
mdconfig -a -t swap -s "${ROOTFS_BYTES}b" -u 2

# Assemble the gunion overlay. md1.uzip = read-only lower, md2 = writable
# upper. Result appears at /dev/md2-md1.uzip.union.
echo "==> creating gunion overlay (md2 over md1.uzip)"
gunion create md2 md1.uzip

UNION_DEV=/dev/md2-md1.uzip.union
if [ ! -e "$UNION_DEV" ]; then
    echo "ERROR: gunion device $UNION_DEV not present after create"
    halt -p
fi

# Unset the init_* kenvs so the kernel doesn't re-run our pivot logic
# on the new root after reroot.
echo "==> clearing init_* kenvs"
kenv -u init_chroot 2>/dev/null || true
kenv -u init_path   2>/dev/null || true
kenv -u init_script 2>/dev/null || true
kenv -u init_shell  2>/dev/null || true

# Tell the kernel where to find the new root after reroot.
kenv vfs.root.mountfrom="ufs:${UNION_DEV}"

# Pivot. /sbin/reboot sends SIGEMT to PID 1 (init), which transitions to
# the reroot state and performs the two-phase reroot dance. The kernel
# unmounts everything except /dev (vfs_unmountall), then re-mounts root
# from vfs.root.mountfrom, then re-execs /sbin/init from the new root.
#
# md1, md2 and the gunion provider all survive because their backing is
# in kernel memory (preload + swap-md), not in any vnode.
echo "==> reboot -r (pivoting to ${UNION_DEV})"
exec reboot -r
