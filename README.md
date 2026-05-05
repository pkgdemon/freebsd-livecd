# freebsd-livecd-gunion

A FreeBSD live ISO build system. Produces a bootable cd9660 image with a
mkuzip-compressed UFS rootfs and a `gunion(8)` writable overlay, pivoted
into via `init_chroot` (FreeBSD's analog of Linux's `switch_root`).

## Download

**[Latest ISO →](https://github.com/pkgdemon/freebsd-livecd-gunion/releases/tag/continuous)**

Continuous build, rebuilt automatically on every push to `main` after the
build + boot smoke-test both pass. Filename pattern:
`FreeBSD-<ver>-<arch>-gunion-<YYYYMMDD>.iso` plus a matching `.sha256`.

## Architecture

```
cd9660 ISO  (kernel root, stays mounted forever, hidden from chroot)
  /boot/kernel/kernel.gz     gzipped kernel; loader auto-decompresses
  /boot/kernel/*.ko          ~8 essential modules only (geom_uzip,
                             geom_union, virtio_*, ahci, acpi, mfi)
  /boot/loader.conf          loads geom_uzip + geom_union, sets
                             init_script=/init.sh + init_shell=/rescue/sh
  /sbin/init -> /rescue/init real FreeBSD init binary (statically linked)
  /sbin/geom                 dynamic; needed for `geom union create`
                             (rescue's static geom can't dlopen classes)
  /rescue/                   statically linked busybox-equivalent
  /lib/, /libexec/           shared libs + ld-elf.so.1 for /sbin/geom
  /lib/geom/geom_union.so    union class library dlopen'd by /sbin/geom
  /init.sh                   pivot script (silent in normal boot)
  /rootfs.uzip               compressed UFS rootfs (the real live system)
  /rootfs.bytes              uncompressed-size sidecar
  /sysroot/                  empty mountpoint for the gunion overlay
  /EFI/BOOT/BOOTX64.EFI      UEFI loader (also inside the El Torito ESP)

Boot flow:

  loader -> kernel
  kernel mounts cd9660 as /
  /sbin/init runs from /rescue/init
  init reads init_script kenv, forks, execs /rescue/sh /init.sh

  /init.sh:
    mdconfig -t vnode -f /rootfs.uzip -u 0     ->  md0
                                                    (geom_uzip auto-tastes
                                                     /dev/md0 -> md0.uzip)
    mdconfig -t swap -s ${UPPER_MB}m -u 1      ->  md1 (writable upper,
                                                    sized at ~50% of host
                                                    RAM, page-allocated
                                                    on demand)
    /sbin/geom union create md1 md0.uzip       ->  md1-md0.uzip.union
    mount /dev/md1-md0.uzip.union /sysroot
    mount -t devfs devfs /sysroot/dev
    kenv init_chroot=/sysroot
    exit 0

  init re-reads init_chroot kenv on the next line of init.c, chroots into
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
MB resident forever, plus a UEFI loader staging-area limit at scale.

`init_chroot` instead leaves the kernel's mount table alone. It works
because of the deliberate ordering at `sbin/init/init.c:326-336`:

```c
if (init_script kenv set)
    run_script(...)             // runs synchronously, blocks
if (init_chroot kenv set)       // RE-READ AFTER the script exits
    chroot(...)
```

The script can `kenv init_chroot=/sysroot` before exiting, and init reads
the value on the next line. This is the helloSystem `geom_rowr` trick.

## Writable headroom

The writable upper is `mdconfig -t swap`, which is **page-allocated on
demand by the VM subsystem**, semantically identical to Linux's tmpfs:

- `-s` is a *maximum*, not a pre-allocation. Empty pages cost zero
  memory.
- Pages back the swap-pager VM object only as files are written.
- Under memory pressure pages spill to system swap.

Default upper size is **50% of host RAM** (matching Linux livecd
convention — Ubuntu casper, Arch archiso both default tmpfs to 50%
of RAM). On a 4 GB system that's a 2 GB ceiling for live writes; on
8 GB, 4 GB. The minimum is whatever gunion's metadata bitmap requires
(~lower size + 10% + 64 MB), so very low-RAM hosts still boot.

The lower UFS is sized at `content + LIVE_HEADROOM` (default 1 GiB) so
the live system reports free space on `df` from boot. Empty UFS blocks
compress to almost nothing under mkuzip's zstd + dedup, so the headroom
costs essentially zero on the ISO.

## Measured sizes

| Build | Content | Compressed (rootfs.uzip) | ISO total |
|---|---|---|---|
| Minimal base (no pkglist) | 803 MiB | 230 MiB | **396 MiB** |
| + xorg + KDE Plasma 6 | 10.3 GiB | 3.7 GiB | **3.8 GiB** |

Compression ratios: ~29% for base content, ~36% for KDE-heavy content.
Comparable to squashfs zstd. Build time on minimal: ~7 min in CI; with
KDE: ~36 min (mkuzip zstd-19 on 10 GiB content is the bottleneck).

## Trade-offs vs Linux squashfs+overlayfs

- Block-level overlay (`gunion`) instead of file-level (`overlayfs`).
  Copy-up is per block (~64 KB), not per file. Tiny edits to many files
  cost more on FreeBSD than Linux.
- The cd9660 mount can't be removed during the live session (the live
  USB stick / CD has to stay attached). Linux livecds have the same
  limitation by default.
- FreeBSD's UEFI loader has a more rigid staging-area design than GRUB,
  so we *cannot* preload the rootfs through the loader. We mount it
  via mdconfig from cd9660 instead — same pattern Linux livecds use
  (`mount -o loop` from the iso9660), so this isn't a real handicap.

## Quickstart

Boot in qemu (UEFI):
```sh
qemu-system-x86_64 -m 4G -bios /usr/share/OVMF/OVMF_CODE.fd \
    -cdrom out/livecd.iso -boot d -nographic -serial mon:stdio
```

Boot under KVM for native speed (if `/dev/kvm` is available):
```sh
qemu-system-x86_64 -m 4G -accel kvm -cpu host \
    -bios /usr/share/OVMF/OVMF_CODE.fd \
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
- `COMPRESS` (default `zstd`; `zlib` for FreeBSD 14 where mkuzip's
  zstd is broken — see [PR 267082](https://bugs.freebsd.org/267082))
- `LABEL` (default `LIVECD`)
- `ARCH` (default `amd64`)
- `LIVE_HEADROOM` (default `1g`) — free space the live system gets in
  addition to installed content. The lower UFS is sized at `content +
  LIVE_HEADROOM`.

## Building in CI

`.github/workflows/build.yml` runs the build inside `vmactions/freebsd-vm`
on `ubuntu-latest`. Each push produces an ISO artifact; a follow-up
job boots it in qemu (KVM if `/dev/kvm` is available, else TCG) and
asserts the live system reaches the getty `login:` prompt — that single
marker confirms the entire pipeline (loader → kernel → cd9660 mount →
init.sh → gunion overlay → init_chroot pivot → multi-user) succeeded.

## Repository layout

```
freebsd-livecd-gunion/
├── build.sh                  orchestrator (runs on FreeBSD)
├── ramdisk/init.sh           pivot script (lives at cd9660 root, silent
│                             at runtime)
├── boot/loader.conf          modules + init_script kenv
├── overlays/etc/rc.conf      live-system rc.conf
├── pkglist.txt               one pkg per line (empty = minimal base)
├── tests/boot-test.sh        qemu+expect smoke test (single login: marker)
├── .github/workflows/        CI
├── LICENSE                   BSD 2-clause, Joseph Maloney
└── README.md
```

## Further reading

[Architecture and design notes](https://pkgdemon.github.io/freebsd-livecd-plan.html)

## License

BSD 2-clause. Copyright (c) 2026, Joseph Maloney. See [LICENSE](./LICENSE).

This project bundles unmodified FreeBSD base and kernel artifacts at
build time; those remain under their original BSD 2-clause license
held by The FreeBSD Foundation and contributors.
