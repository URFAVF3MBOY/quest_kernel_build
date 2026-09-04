# kgdb over USB — Quest 3 (eureka)

Attach gdb to the running Quest 3 kernel **over the USB cable**. No UART, no
opening the headset. Verified end to end: symbolized backtraces and kernel
memory reads.

```
#0  arch_kgdb_breakpoint () at ./arch/arm64/include/asm/kgdb.h:21
#1  kgdb_breakpoint ()      at kernel/debug/debug_core.c:1261
#2  sysrq_handle_dbg        at kernel/debug/debug_core.c:1002
#7  vfs_write               at fs/read_write.c:603
x/s &linux_banner → "Linux version 5.10.240-DARK-… clang version 14.0.7 …"
```

## Contents

| file | what it is |
|---|---|
| `apply-kgdb-usb-transport.py` | the kernel patch (4 files, ~430 lines). Idempotent, anchor-checked. Applied by `build.sh` when `KGDB=1` |
| `check-vendor-kabi.py` | **run before every boot test.** Catches the failure mode that silently bricks boots |
| `vendor-kabi.json.gz` | symbol→CRC baseline extracted from the device's 246 vendor modules (96 KB), stamped with the firmware fingerprint it came from |
| `arm.sh` | host-side driver: composes the gadget and arms kgdb, in one go |
| `acm-compose.sh` | on-device: adds the CDC-ACM gadget function (pushed by `arm.sh`) |
| `acm-watchdog.sh` | on-device: **safety net** for the above — never run one without the other |

Everything is used *from this folder*; `build.sh` writes nothing kgdb-related
into the build output, so there is only ever one copy to keep in sync.

### The baseline describes the *firmware*, not your build

`vendor-kabi.json.gz` is a snapshot of the CRCs **the headset's currently
installed vendor modules demand**. It has nothing to do with the kernel you
just built, and it stays valid only until the headset takes an OTA — after
which it describes modules that are no longer installed. That is the same
stale-input trap a mismatched `boot.img` caused.

So it records the firmware fingerprint it was taken from, and the checker
compares that against the attached device:

```
baseline firmware: oculus/eureka/eureka:14/UP1A.231005.007.A1/523453…
  matches the attached device
```

If the headset has been updated you get `*** STALE BASELINE ***` instead.
Fix with `./check-vendor-kabi.py --refresh` — **and re-pull `boot.img`**,
since its ramdisk goes stale for the same reason.

## Build & run

```sh
KGDB=1 ./build.sh device-only        # from q3_build/
./kgdb/check-vendor-kabi.py          # must PASS before booting
fastboot boot build/oculus-quest3-device-kernel/boot-repacked.img
```

`KGDB=1` defaults the boot.img cmdline to `nokaslr`, because
`CONFIG_RANDOMIZE_BASE=y` and without it gdb resolves nothing — every frame
is `?? ()` and data symbols cannot be read. Set `KERNEL_CMDLINE` to
override, or to `""` to suppress it.

Then, from this folder — composes the gadget, arms the transport, and
proves it works **without stopping the CPU** (so a failure costs no reboot):

```sh
./arm.sh --selftest     # expect: SELFTEST PASS - transport works
./arm.sh --status       # re-check state any time
```

Then break in:

```sh
adb shell 'echo g > /proc/sysrq-trigger'    # CPU stops here
gdb-multiarch vmlinux
(gdb) target remote /dev/ttyACM0
```

## The three things that made this hard

**1. Changing any KABI-visible struct silently bricks the boot.**
`CONFIG_MODVERSIONS=y` + 270 prebuilt vendor modules. `KGDB_SERIAL_CONSOLE`
selects `CONSOLE_POLL`, which inserts fields into the *middle* of
`tty_operations` and `uart_ops` → every tty/serial CRC changes → modules
refuse to load → falls back to the stock kernel, with no log
(`ramoops` is deleted from the eureka DT). This is why the poll hook is a
standalone exported pointer, not a member of `usb_gadget_ops`.

**2. kgdboc cannot work over USB.** It only binds a tty exposing
`poll_get_char`/`poll_put_char`; nothing under `drivers/usb/gadget/`
implements them. But kgdboc is only one `struct kgdb_io` — registering our
own needs just `CONFIG_KGDB=y`, and `debug_core` installs sysrq-g itself.
**The config delta from stock is one symbol.**

**3. `dwc->lock` — the expensive one.** kgdb stops every other CPU, any of
which may hold it. Taking it deadlocks; the SoC watchdog then resets the
headset, which looks exactly like a kernel crash. Three sites must skip it
under `in_dbg_master()`:

* `dwc3_gadget_poll()` — drains the event ring
* `dwc3_gadget_ep_queue()` — submits the transfer
* `dwc3_gadget_giveback()` — normally drops+retakes the lock around the
  completion callback; unlocking one we never took corrupts it

Outside kgdb they *must* still take it: with only local interrupts off,
other CPUs still take the dwc3 interrupt. An unconditionally-unlocked build
crashed the kernel seconds after its self-test bytes had reached the host.

## Session length: the watchdog

Nothing pets `qcom_wdt_core` while the CPUs are stopped, so by default the
SoC resets after ~10–30 s of halt. It **can** be disabled — the param is
`0444`, but it is read at module load and first-stage init uses Android's
libmodprobe, which honours `modules.options`. Append one to the boot
ramdisk:

```sh
mkdir -p extra/lib/modules
echo 'options qcom_wdt_core disable_wdt=1' > extra/lib/modules/modules.options
( cd extra && find . | cpio -o -H newc | lz4 -l -9 ) > extra.lz4
cat build/bootimg-unpacked/ramdisk extra.lz4 > ramdisk-nowdt   # concatenated
                                                               # cpio segments
mkbootimg … --ramdisk ramdisk-nowdt …
```

Verified: `disable_wdt=Y`, and a halt held **290 s** fully responsive
(vs 10–30 s before). SELinux enforcing and adb root are unaffected.

**But do not use a watchdog-disabled image for iteration.** With it off, a
wedged kernel cannot self-recover and the headset needs a physical power
cycle — which cost real time during development. Iterate on a
watchdog-enabled image (a wedge then resets itself) and only disable it for
long inspection sessions.

`core_hang_detect` cannot be disabled the same way: it loads in *second*
stage from `/vendor_dlkm` (read-only, dm-verity), which the first-stage
`modules.options` cannot reach.

## Limits
* Breaking in from inside dwc3 itself is not safe, by construction.
* The chosen `ttyGS` must not also be used by userspace.
* **Never let gdb exit while the target is halted.** Our poll only runs
  while kgdb is doing I/O, so with no debugger attached nothing services
  the controller, USB drops, and there is no way back in. Always `detach`
  (or `continue`) first — a `-batch` script that ends without it strands
  the headset.

## The lock rule that makes resume work

kgdb stops every other CPU, and any of them may have been holding
`dwc->lock`. Three sites in dwc3 are involved: `dwc3_gadget_ep_poll()`,
`dwc3_gadget_ep_queue()` and `dwc3_gadget_giveback()`.

The tempting move is to *skip* the lock while `in_dbg_master()` — "every
other CPU is stopped, so there is nothing to race with". That is wrong in
exactly the case that matters: if a stopped CPU **holds** the lock,
mutating dwc3 state corrupts the critical section it resumes into. It looks
perfect while halted, then after resume `ffs.adb`'s endpoints are broken —
adbd stays alive but every `adb shell` hangs forever.

The rule is instead: **always hold the lock, never wait for it.**

```c
if (in_dbg_master()) {
        if (!spin_trylock_irqsave(&dwc->lock, flags))
                return;          /* a stopped CPU owns it - do nothing */
} else {
        spin_lock_irqsave(&dwc->lock, flags);
}
```

With the machine stopped a free lock cannot be contended, so `trylock`
either succeeds (safe) or tells us a stopped CPU owns it — in which case
the only safe move is to do nothing and let the debugger time out. Losing a
debug session beats corrupting the kernel you are debugging. Because the
lock is genuinely held, `dwc3_gadget_giveback()` needs no special case at
all: its normal drop/retake around the completion callback is correct.

Two designs were tried and rejected on the way, both measured:

* **Complete only our endpoint, never touch the ring.** Kills USB — nothing
  answers the host, the device leaves the bus in seconds, gdb cannot even
  connect.
* **Drain the ring but defer/stash other functions' work.** Connects and
  holds fine, but still wedges on resume, because the real problem was the
  lock, not the callbacks. Stashing ep0 and device events as well is worse
  still: the link dies before gdb attaches.

## Verified

| | |
|---|---|
| minimal halt, resume | 3/3 clean |
| 60 s halt, resume | clean |
| 120 s halt + backtraces + memory reads, resume | clean |

After a 120 s session: uptime shows no reset, SELinux `Enforcing`, 682
processes, binder working (`am start` succeeds). The one dmesg complaint is
`BUG: workqueue lockup … stuck for 124s`, which is simply the workqueue
watchdog noticing that nothing ran while every CPU was deliberately
stopped. Harmless.
