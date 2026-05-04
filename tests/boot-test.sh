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

# Generate the expect script. Pass the ISO path as the first argument.
cat > "$EXP" <<'EOF'
set timeout 360
log_file -a tests/boot.log
log_user 1

set iso [lindex $argv 0]

spawn qemu-system-x86_64 \
    -m 4G \
    -accel tcg,thread=single \
    -cpu qemu64 \
    -cdrom $iso -boot d \
    -nographic -serial mon:stdio -display none \
    -no-reboot

# Stage 1: kernel + loader come up
expect {
    timeout {
        puts "\nFAIL: no kernel banner within 6 minutes"
        exit 1
    }
    "FreeBSD"   { puts "\nstage 1 OK: FreeBSD banner observed" }
}

# Stage 2: pivot script ran
expect {
    timeout {
        puts "\nFAIL: livecd init.sh did not start within 6 minutes"
        exit 1
    }
    "livecd init.sh: starting" { puts "stage 2 OK: init.sh started" }
}

# Stage 3: gunion overlay created and reroot issued
expect {
    timeout {
        puts "\nFAIL: reboot -r not reached within 6 minutes"
        exit 1
    }
    "reboot -r" { puts "stage 3 OK: reboot -r issued" }
}

# Stage 4: post-pivot multi-user boot reached rc.local
expect {
    timeout {
        puts "\nFAIL: SMOKE_TEST_DONE not seen within 6 minutes -- pivot likely failed"
        exit 1
    }
    "SMOKE_TEST_DONE" { puts "stage 4 OK: rc.local executed on new root" }
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
