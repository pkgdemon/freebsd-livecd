#!/bin/sh
# boot-test.sh — boot the live ISO in qemu (TCG, BIOS) and watch the serial
# console for the smoke-test markers emitted by /etc/rc.local.

set -eu

ISO=${1:?usage: boot-test.sh path/to/livecd.iso}

if [ ! -f "$ISO" ]; then
    echo "ERROR: $ISO not found"
    exit 1
fi

mkdir -p tests
LOG=tests/boot.log
EXP=tests/boot.exp

echo "==> boot test: $ISO"
ls -lh "$ISO"

# Pick acceleration. KVM if available; TCG fallback. Both work via the
# UEFI path below (UEFI/OVMF + loader.efi avoids the BTX legacy code that
# crashes both KVM (suberror 3 / pusha in long mode) and TCG (qemu 8.x
# iothread mutex assertion).
if [ -e /dev/kvm ]; then
    sudo chmod 666 /dev/kvm 2>/dev/null || true
fi
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL_FLAGS="-accel kvm -cpu host"
    echo "==> using KVM acceleration"
else
    ACCEL_FLAGS="-accel tcg,thread=single -cpu qemu64"
    echo "==> using TCG (single-thread)"
fi

# Find OVMF firmware (split or unified format depending on Ubuntu version)
OVMF=""
for f in /usr/share/OVMF/OVMF_CODE.fd \
         /usr/share/ovmf/OVMF.fd \
         /usr/share/qemu/OVMF.fd; do
    if [ -f "$f" ]; then
        OVMF="$f"
        break
    fi
done
if [ -z "$OVMF" ]; then
    echo "ERROR: no OVMF firmware found"
    exit 1
fi
echo "==> using UEFI firmware: $OVMF"

export ACCEL_FLAGS OVMF

# Generate the expect script. ISO path passed as first argv.
cat > "$EXP" <<'EOF'
set timeout 480
log_file -a tests/boot.log
log_user 1

set iso [lindex $argv 0]
set accel_flags [split $env(ACCEL_FLAGS) " "]

eval spawn qemu-system-x86_64 \
    -m 4G \
    -machine q35 \
    -bios $env(OVMF) \
    $accel_flags \
    -cdrom $iso -boot d \
    -display none -serial stdio \
    -no-reboot

# Stage 1: kernel + loader come up
expect {
    timeout {
        puts "\nFAIL: no kernel banner within 6 minutes"
        exit 1
    }
    "FreeBSD"   { puts "\nstage 1 OK: FreeBSD banner observed" }
}

# Stage 2: init.sh started running
expect {
    timeout {
        puts "\nFAIL: livecd init.sh did not start within 6 minutes"
        exit 1
    }
    "livecd init.sh: starting" { puts "stage 2 OK: init.sh started" }
}

# Stage 3: gunion overlay built and init.sh signaled chroot
expect {
    timeout {
        puts "\nFAIL: init_chroot pivot signal not reached within 6 minutes"
        exit 1
    }
    "exiting; init will chroot" { puts "stage 3 OK: init_chroot pivot signaled" }
}

# Stage 4: multi-user boot reached rc.local in the chroot
expect {
    timeout {
        puts "\nFAIL: SMOKE_TEST_DONE not seen within 6 minutes -- chroot/rc.local likely failed"
        exit 1
    }
    "SMOKE_TEST_DONE" { puts "stage 4 OK: rc.local executed inside chroot" }
}

# Stage 5: write to root succeeded
expect {
    timeout {
        puts "\nFAIL: WRITE_OK not seen -- root may not be writable"
        exit 1
    }
    "WRITE_OK" { puts "stage 5 OK: root is writable" }
    "WRITE_FAIL" { puts "\nFAIL: write to root failed (WRITE_FAIL marker)"; exit 1 }
}

# Cleanly shut down via qemu monitor
send "\x01"
send "c"
expect "(qemu)"
send "quit\r"
expect eof
exit 0
EOF

# Run the test
expect "$EXP" "$ISO"
echo "==> boot-test PASSED"
