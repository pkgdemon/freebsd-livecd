# freebsd-livecd

A FreeBSD live ISO build system: produces a bootable cd9660 image with a
mkuzip-compressed UFS rootfs and a `gunion(8)` writable overlay, pivoted
into via `reboot -r`. Modeled on Linux livecd architecture (squashfs +
overlayfs + switch_root) using FreeBSD-native primitives.

## Architecture

```
cd9660 ISO
  ├── /boot/kernel/kernel      ← FreeBSD kernel
  ├── /boot/mfsroot            ← small init ramdisk (UFS, gzipped)
  ├── /boot/rootfs.uzip        ← compressed UFS rootfs (the real root)
  └── /boot/loader.conf        ← preloads BOTH images as md devices

Boot:
  loader → kernel + md0 (mfsroot, init ramdisk)
                  + md1 (rootfs.uzip, real root) via md_image preload
  geom_uzip auto-tastes md1 → /dev/md1.uzip
  init runs /init.sh from mfsroot:
    mdconfig -t swap -s ${rootfs_size} -u 2     # writable upper
    gunion create md2 md1.uzip                   # block-level overlay
    kenv vfs.root.mountfrom=ufs:/dev/md2-md1.uzip.union
    reboot -r                                    # pivot to overlay
  → live system runs with fully writable rootfs
```

Why preload? The kernel forces unmount of all filesystems during `reboot -r`
(`vfs_unmountall()` uses `MNT_FORCE`). A vnode-backed `mdconfig -t vnode -f
/cdrom/...` would lose its backing during this unmount and fail. Preloading
via the loader puts the rootfs.uzip in kernel memory from boot, decoupled
from any filesystem mount.

## What you get

- A hybrid BIOS+UEFI bootable ISO under 500 MB (target).
- Fully writable rootfs in the live environment (writes captured in a
  swap-backed memory disk).
- Standard FreeBSD base + kernel from the official release mirror — no
  buildworld required.
- Reproducible builds via GitHub Actions; tagged releases attach the ISO
  to GitHub Releases automatically.

## Quickstart

Boot the latest release in qemu:

```sh
qemu-system-x86_64 -m 4G -cdrom out/livecd.iso -boot d \
    -nographic -serial mon:stdio
```

Write to a USB stick (replace `/dev/sdX` with your stick's device):

```sh
sudo dd if=out/livecd.iso of=/dev/sdX bs=1M status=progress conv=fsync
```

## Building locally

Requires a FreeBSD 15.0+ machine or VM:

```sh
sh build.sh
ls -lh out/livecd.iso
```

Environment knobs:

- `FREEBSD_VERSION` (default `15.0`) — release tag in
  `https://download.freebsd.org/ftp/releases/amd64/`
- `COMPRESS` (default `zstd`, alternative `zlib`) — mkuzip algorithm
- `LABEL` (default `LIVECD`) — ISO volume label

## Building in CI

`.github/workflows/build.yml` runs the build inside `vmactions/freebsd-vm`
on `ubuntu-latest`. Each push produces an ISO artifact; a follow-up job
boots it in qemu/TCG and asserts the live system reaches multi-user with
a writable union root.

## Repository layout

```
freebsd-livecd/
├── build.sh                  # orchestrator (runs on FreeBSD)
├── ramdisk/init.sh           # pivot script (runs in mfs_root)
├── boot/loader.conf          # preloads mfsroot + rootfs.uzip
├── overlays/                 # files merged into the live rootfs
├── pkglist.txt               # one pkg per line (empty for minimal)
├── tests/boot-test.sh        # qemu+expect smoke test
├── .github/workflows/        # CI
├── LICENSE                   # BSD 2-clause
└── README.md
```

## License

BSD 2-clause. Copyright (c) 2026, Joseph Maloney. See [LICENSE](./LICENSE).

This project bundles unmodified FreeBSD base and kernel artifacts at build
time; those remain under their original BSD 2-clause license held by The
FreeBSD Foundation and contributors.
