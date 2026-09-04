# kgdb over USB — Quest 1 (monterey)

Attach gdb to the running Quest 1 kernel **over the USB cable**. No UART, no
opening the headset. Verified end to end on 4.4.205-perf+ — symbolized
backtraces, kernel memory reads, and clean resume from halts of up to
**10 minutes**:

```
#0  kgdb_breakpoint ()      at ./arch/arm64/include/asm/kgdb.h:32
#1  sysrq_handle_dbg ()     at kernel/debug/debug_core.c:825
#2  __handle_sysrq ()       at drivers/tty/sysrq.c:557
#3  write_sysrq_trigger ()  at drivers/tty/sysrq.c:1103
#5  vfs_write ()            at fs/read_write.c:491
#7  el0_svc ()              at arch/arm64/kernel/entry.S:956
x/s &linux_banner → "Linux version 4.4.205-perf+ … #10 SMP PREEMPT …"
```

## Contents

| file | what it is |
|---|---|
| `apply-kgdb-usb-transport.py` | the kernel patch (4 files). Idempotent, anchor-checked. Applied by `build.sh` when `KGDB=1` |
| `arm.sh` | host-side driver: composes the CDC-ACM gadget function and arms the transport, in one go |
| `acm-compose.sh` | on-device: adds the ACM gadget function (pushed by `arm.sh`) |
| `acm-watchdog.sh` | on-device: **safety net** for the above — never run one without the other |

Everything is used *from this folder*; `build.sh` writes nothing kgdb-related
into the build output, so there is only ever one copy to keep in sync.

## Build & run

```sh
KGDB=1 REAL_BOOT_IMG=/path/to/boot.img ./build.sh device-only   # from q1_build/
fastboot boot build/oculus-quest1-device-kernel/boot-repacked.img
./kgdb/arm.sh --selftest      # compose ACM, arm, prove the transport (no halt)

adb shell 'echo g > /proc/sysrq-trigger'
gdb-multiarch build/oculus-quest1-device-kernel/vmlinux
(gdb) target remote /dev/ttyACM0
(gdb) bt
(gdb) detach
```

`KGDB=1` adds `nokaslr` to the repacked cmdline, because
`CONFIG_RANDOMIZE_BASE=y` here and without it gdb resolves nothing — every
frame is `?? ()` and data symbols cannot be read.

The whole config delta is:

```
CONFIG_KGDB=y
# CONFIG_KGDB_SERIAL_CONSOLE is not set
CONFIG_USB_CONFIGFS_ACM=y     (selects USB_U_SERIAL + USB_F_ACM)
```

A `KGDB=1` kernel boots and behaves exactly like a stock one until armed:
`u_serial.kgdb_port` defaults to `-1` and the transport does nothing. Use the
`kgdb_selftest` module param (what `--selftest` writes) before any break-in —
it pushes bytes through the transport with interrupts off but *without*
stopping the machine, so it validates the path at zero risk.

## Why not kgdboc

kgdboc only accepts a tty whose ops provide `poll_get_char`/`poll_put_char`,
and nothing under `drivers/usb/gadget/` implements them — so
`echo ttyGS0 > /sys/module/kgdboc/parameters/kgdboc` can only ever fail.

But kgdboc is just one implementation of `struct kgdb_io`. kgdb itself needs
neither it, nor a tty, nor `CONSOLE_POLL`: `kgdb_register_io_module()` is
exported with plain `CONFIG_KGDB=y` and wants only a read_char/write_char
pair, and `debug_core` registers sysrq-g itself. So this registers a private
`kgdb_io` that drives the gadget's bulk endpoints directly.

## The lock rule

kgdb stops every other CPU, any of which may hold `dwc->lock`.

* **Waiting** for it deadlocks, and the watchdog then resets the headset —
  which looks exactly like "the kernel crashed".
* **Skipping** it because "everything is stopped, nothing can race" is wrong:
  if a stopped CPU holds it, mutating dwc3 state corrupts the critical
  section it resumes into. On Quest 3 this produced a brutal symptom —
  halting looked perfect for minutes, then after resume `adbd` stayed alive
  while every `adb shell` hung forever.

So: **always hold the lock, never wait for it.** `spin_trylock_irqsave()` in
kgdb context; if it fails, do nothing and let the debugger time out. Losing a
session beats corrupting the kernel. Because the lock is then genuinely held,
`dwc3_gadget_giveback()` needs no special case and this patch does not touch
it.

## What differs from the Quest 3 version

Quest 1 is a much friendlier target than Quest 3:

* **No vendor-module KABI constraint.** Quest 3 boots ~270 prebuilt vendor
  modules under `CONFIG_MODVERSIONS=y`, so any struct change silently breaks
  boot. Quest 1 loads **no modules at all** (`lsmod` is empty,
  `/vendor/lib/modules` does not exist), so config changes are cheap and
  `check-vendor-kabi.py` has no counterpart here.
* **The watchdogs are cmdline tokens.** Quest 3 needed an extra cpio segment
  appended to the boot ramdisk to set a module param. Here both watchdogs are
  builtin, so `KGDB_DISABLE_WDT=1` just appends two tokens (see below).
* **pstore works.** Quest 3's DT does `/delete-node/ &ramoops_mem`, so a
  crash leaves no log at all. On Quest 1
  `/sys/fs/pstore/console-ramoops-0` survives a reset and holds the whole
  kernel log — which is how the softdog below was identified in one shot
  rather than by bisection. Always look there first after an unexpected
  reset, and check `getprop ro.boot.bootreason`.
* **dwc3 internals.** 4.4 has an array of event buffers (`dwc->ev_buffs[]`,
  `num_normal_event_buffers`) where 5.10 has one, and takes `dwc->lock` at
  the top of `dwc3_gadget_ep_queue()` rather than around one call. See
  "QUEST 1 DELTAS" in `apply-kgdb-usb-transport.py`.
* **No `vendor.usb_default` service.** Composition is driven purely by
  `on property:sys.usb.config=…` triggers in `/init.usb.configfs.rc`, so
  nothing re-asserts it and `acm-compose.sh` has no service to stop.

## The two watchdogs

Both have to go for a long halt. Disabling only the first is not enough,
which is how the second was found:

1. `watchdog_v2.enable=0` — the SoC watchdog.
2. `softdog.soft_noboot=1` — the **software** watchdog. `CONFIG_SOFT_WATCHDOG=y`
   and Android's `watchdogd` opens `/dev/watchdog` at boot with a 30 s margin,
   and nothing pets it while the CPUs are stopped. The stock cmdline carries
   `softdog.soft_panic=1`, so it panics the kernel:

   ```
   softdog: Initiating panic
   Kernel panic - not syncing: Software Watchdog Timer expired
   ```

   Measured on a 60 s halt: gdb detached cleanly and the kernel resumed, then
   died **~69 s after entering kgdb** — the death is delayed past the resume,
   which is what makes it confusing. `soft_noboot=1` changes the *action* to a
   warning, which is robust; raising `soft_margin` is not, because `watchdogd`
   overrides the timeout via ioctl at runtime, and `CONFIG_WATCHDOG_NOWAYOUT=y`
   means stopping `watchdogd` would not disarm it either.

`KGDB_DISABLE_WDT=1` appends both. **Verified with a 10-minute halt**: gdb
stayed responsive throughout (register and memory reads at T+2/4/6/8/10 min),
detached cleanly, and the kernel resumed with no reboot — uptime kept climbing
past the 600 s hold, 592 processes, SELinux still enforcing, binder serving
182 services, and no BUG/WARN/lockup in dmesg. The only complaint was

```
softdog: Triggered - Reboot ignored
```

i.e. the software watchdog fired exactly as expected and `soft_noboot=1`
turned it into a no-op.

By default both are left **enabled**, which caps a session at roughly 10–30 s
but means a wedge self-recovers (the headset resets and comes back on the
stock kernel). Iterate that way; turn them off for long inspection, where a
wedge then needs a physical power cycle.

## Known limits

* Breaking in from inside dwc3 itself is not safe.
* The chosen ttyGS port must not be in use by userspace at the same time —
  kgdb and a getty on the same port will corrupt each other.
* `fastboot boot` is one-shot: any reboot returns the headset to its stock
  kernel, and the ACM function is volatile, so re-run `arm.sh` after each
  boot.
* Always `detach` before gdb exits.
* `uname -r` alone does **not** distinguish this kernel from stock — both are
  `4.4.205-perf+`. Use `uname -v` (build number and date).
