#!/bin/bash
# Arm kgdb-over-USB on a Quest 3 already running a KGDB=1 kernel.
#
# Run from the host, from this directory. Pushes the two on-device helpers
# straight out of kgdb/ (nothing is staged into the build output), composes
# the CDC-ACM gadget function, and arms the transport.
#
# Usage:
#   ./arm.sh                 # compose + arm
#   ./arm.sh --selftest      # ...then prove the transport without halting
#   ./arm.sh --status        # just report current state
#
# Assumes a plain Linux host with the headset already visible to adb and
# its CDC-ACM port appearing as /dev/ttyACM*. Composing the gadget bounces
# the UDC, so the device re-enumerates several times and adb briefly goes
# away; this just waits it out. Keeping the device attached across those
# re-enumerations is somebody else's job (a real Linux box does it itself;
# under WSL, an auto-attach loop).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB="${ADB:-adb}"
TTY="${KGDB_TTY:-/dev/ttyACM0}"
PORT="${KGDB_PORT:-0}"

log() { printf '\n== %s ==\n' "$*"; }

wait_for_device() {
  local tries=${1:-24} i
  for ((i = 0; i < tries; i++)); do
    "$ADB" devices 2>/dev/null | grep -q "device$" && return 0
    sleep 3
  done
  return 1
}

status() {
  log "status"
  echo "kernel:    $(timeout 20 "$ADB" shell uname -r 2>&1)"
  echo "kgdb_port: $(timeout 20 "$ADB" shell 'cat /sys/module/u_serial/parameters/kgdb_port 2>/dev/null || echo "(missing - not a KGDB=1 kernel)"' 2>&1)"
  echo "sysrq:     $(timeout 20 "$ADB" shell 'cat /proc/sys/kernel/sysrq' 2>&1)"
  echo "functions: $(timeout 20 "$ADB" shell 'ls /config/usb_gadget/g1/configs/b.1/ 2>/dev/null | grep -c function' 2>&1)"
  echo "host tty:  $(ls $TTY 2>/dev/null || echo '(none)')"
  timeout 20 "$ADB" shell 'dmesg | grep -i KGDB_USB | tail -3' 2>&1
}

wait_for_device 12 || { echo "no device over adb" >&2; exit 1; }

if [ "${1:-}" = "--status" ]; then status; exit 0; fi

log "root"
timeout 30 "$ADB" root >/dev/null 2>&1
sleep 6
wait_for_device 20 || { echo "device did not come back after adb root" >&2; exit 1; }

if ! timeout 20 "$ADB" shell 'ls /sys/module/u_serial/parameters/kgdb_port' >/dev/null 2>&1; then
  echo "ERROR: /sys/module/u_serial/parameters/kgdb_port missing." >&2
  echo "This kernel was not built with KGDB=1. uname: $(timeout 20 "$ADB" shell uname -r 2>&1)" >&2
  exit 1
fi

log "composing acm.kgdb gadget function"
timeout 60 "$ADB" push "$HERE/acm-compose.sh" "$HERE/acm-watchdog.sh" /data/local/tmp/ >/dev/null 2>&1
timeout 30 "$ADB" shell 'chmod +x /data/local/tmp/acm-*.sh; rm -f /data/local/tmp/acm-*.log' >/dev/null 2>&1
# Detached: composing bounces the UDC, which kills this adb shell.
timeout 60 "$ADB" shell 'nohup setsid sh /data/local/tmp/acm-compose.sh >/dev/null 2>&1 &' >/dev/null 2>&1

echo "waiting for the ACM port to enumerate..."
for ((i = 0; i < 40; i++)); do
  [ -e "$TTY" ] && break
  sleep 4
done
wait_for_device 20 >/dev/null 2>&1

if [ ! -e "$TTY" ]; then
  echo "WARNING: $TTY did not appear." >&2
  timeout 20 "$ADB" shell 'tail -5 /data/local/tmp/acm-compose.log; echo ---; tail -5 /data/local/tmp/acm-watchdog.log' >&2 2>&1
  echo "(the watchdog rolls the function back out, so USB should still work)" >&2
fi

log "arming transport on ttyGS$PORT"
timeout 30 "$ADB" shell "echo $PORT > /sys/module/u_serial/parameters/kgdb_port; echo 1 > /proc/sys/kernel/sysrq" 2>&1

if [ "${1:-}" = "--selftest" ]; then
  log "selftest (no halt, no reboot risk)"
  [ -e "$TTY" ] && sudo stty -F "$TTY" raw -echo 115200 2>/dev/null
  rm -f /tmp/kgdb-selftest.bin
  ( sudo timeout 12 cat "$TTY" > /tmp/kgdb-selftest.bin 2>/dev/null & )
  sleep 2
  timeout 30 "$ADB" shell 'echo 1 > /sys/module/u_serial/parameters/kgdb_selftest' 2>&1
  sleep 8
  echo -n "received: "; cat /tmp/kgdb-selftest.bin 2>/dev/null; echo
  grep -q ABCDEFGH /tmp/kgdb-selftest.bin 2>/dev/null \
    && echo "SELFTEST PASS - transport works" \
    || echo "SELFTEST FAIL - do not attempt a break-in yet"
fi

status

cat <<EOF

Ready. To break in (the CPU stops until gdb attaches):

    $ADB shell 'echo g > /proc/sysrq-trigger'
    gdb-multiarch <path to>/vmlinux
    (gdb) target remote $TTY

Keep commands short - the SoC watchdog resets the headset after roughly
10-30s with the CPUs stopped. See README.md.
EOF
