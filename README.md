# freebsd-livecd

A FreeBSD live ISO build system. Produces a bootable cd9660 image with a
mkuzip-compressed UFS rootfs and a `gunion(8)` writable overlay, pivoted
into via `init_chroot` (FreeBSD's analog of Linux's `switch_root`).

## Architecture

```
cd9660 ISO  (kernel root, stays mounted forever, hidden from chroot)
  /boot/kernel/kernel
  /boot/loader.conf       loader preloads geom_uzip + geom_union, sets
                          init_script=/init.sh + init_shell=/rescue/sh
  /sbin/init -> /rescue/init   real FreeBSD init binary (statically linked)
  /rescue/                statically linked busybox-equivalent
  /init.sh                pivot script
  /rootfs.uzip            compressed UFS rootfs (the real live system)
  /rootfs.bytes           uncompressed-size sidecar
  /sysroot/               empty mountpoint for the gunion overlay

Boot flow:

  loader -> kernel
  kernel mounts cd9660 as /
  /sbin/init runs from /rescue/init
  init reads init_script kenv, forks, execs /rescue/sh /init.sh

  /init.sh:
    mdconfig -t vnode -f /rootfs.uzip -u 0   ->  md0
                                                  (geom_uzip auto-tastes
                                                   /dev/md0 -> md0.uzip)
    mdconfig -t swap -s ${ROOTFS_MB}m -u 1   ->  md1 (writable upper)
    geom union create md1 md0.uzip           ->  md1-md0.uzip.union
    mount /dev/md1-md0.uzip.union /sysroot
    mount -t devfs devfs /sysroot/dev
    kenv init_chroot=/sysroot
    exit 0

  init reads init_chroot kenv on the next line of init.c, chroots into
  /sysroot, then continues to runcom -> /etc/rc -> multi-user.
```

The cd9660 stays mounted as the kernel's actual `/`. Userland sees the
gunion union as `/`. The `/rootfs.uzip` file backing md0 lives on the
cd9660, which is never unmounted, so the vnode reference stays valid.
Only decompressed pages of accessed uzip data live in the page cache —
the full compressed image is never copied into kernel memory (unlike a
loader preload).

## Why this design

The naive "pivot via `reboot -r`" approach forces FreeBSD's
`vfs_unmountall(MNT_FORCE)`, which orphans any vnode-backed md and
breaks the gunion stack. Working around that requires preloading the
entire rootfs.uzip into kernel memory at boot — typically hundreds of
MB resident forever.

`init_chroot` instead leaves the kernel's mount table alone. It works
because of the deliberate ordering at `sbin/init/init.c:326-336`:

```c
if (init_script kenv set)
    run_script(...)             // runs synchronously, blocks
if (init_chroot kenv set)       // RE-READ AFTER script exits
    chroot(...)
```

The script can `kenv init_chroot=/sysroot` before exiting, and init reads
the value on the next line. This is the helloSystem `geom_rowr` trick.

## Goals hit

- Small ISO (target under 500 MB).
- Fast boot (no preload memory copy; loader stays under a few seconds).
- Read-write rootfs (gunion overlay; writes captured in swap-md upper).
- Low memory (~50-100 MB resident; only decompressed pages stay in RAM).
- Switch_root-equivalent pivot (init_chroot).
- No buildworld required (uses official base.txz + kernel.txz).

## Trade-offs vs Linux squashfs+overlayfs

- Block-level overlay (`gunion`) instead of file-level (`overlayfs`).
  Practical effect: copy-up is per block, not per file.
- The cd9660 mount can't be removed during the live session (the live
  USB stick / CD has to stay attached). Linux livecds have the same
  limitation by default.

## Quickstart

Boot in qemu:
```sh
qemu-system-x86_64 -m 4G -bios /usr/share/OVMF/OVMF_CODE.fd \
    -cdrom out/livecd.iso -boot d -nographic -serial mon:stdio
```

Write to a USB stick:
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
- `FREEBSD_VERSION` (default `15.0`)
- `COMPRESS` (default `zstd`, alternative `zlib`)
- `LABEL` (default `LIVECD`)

## Building in CI

`.github/workflows/build.yml` runs the build inside `vmactions/freebsd-vm`
on `ubuntu-latest`. Each push produces an ISO artifact; a follow-up job
boots it in qemu and asserts the live system reaches multi-user via
`init_chroot` and is writable.

## Repository layout

```
freebsd-livecd/
├── build.sh                  orchestrator (runs on FreeBSD)
├── ramdisk/init.sh           pivot script (lives at cd9660 root)
├── boot/loader.conf          preloads geom modules + init_script kenv
├── overlays/                 files merged into the live rootfs
├── pkglist.txt               one pkg per line (empty = minimal base)
├── tests/boot-test.sh        qemu+expect smoke test
├── .github/workflows/        CI
├── LICENSE                   BSD 2-clause
└── README.md
```

## License

BSD 2-clause. Copyright (c) 2026, Joseph Maloney. See [LICENSE](./LICENSE).

This project bundles unmodified FreeBSD base and kernel artifacts at
build time; those remain under their original BSD 2-clause license held
by The FreeBSD Foundation and contributors.
