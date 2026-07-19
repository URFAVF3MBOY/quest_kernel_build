# Reproducing: Oculus Quest 1 kernel build + QEMU/Buildroot boot

This documents exactly what was done to (1) cross-compile the
`oculus-linux-kernel` (branch `oculus-quest-kernel-master`) for real
Quest 1 hardware using a supplied `kernel.config`, and (2) get a
QEMU-bootable variant of the same source tree running under
`qemu-system-aarch64` with a Buildroot-built rootfs.

Everything below is captured in `build.sh` in this directory — read this
file for the *why*, run `build.sh` for the *how*.

## Files in this kit

- `build.sh` — end-to-end automated build (toolchains, both kernel
  variants, Buildroot, run script). Idempotent-ish: safe to re-run.
- `oculus-kernel-fixes.patch` — the source-tree diff (see below) for
  files git already tracks.
- `kernel.config` — copy of the input config (the real-device config
  you supplied).
- `README-REPRODUCE.md` — this file.

Everything here was built and verified against
`oculus-linux-kernel` commit `6929f734ce0e602018790ff3a52dc7bad646af60`
("Re-sync with internal repository (#235)") on
`oculus-quest-kernel-master`. The patch has been verified to apply
cleanly to a fresh clone of that exact commit; if `oculus-quest-kernel-master`
has moved on, `git apply` may need `--3way` or manual conflict resolution.

## What you need before running

- A `kernel.config` file (the real-device .config you're starting from)
  in the same directory as `build.sh`.
- Ubuntu/Debian host, x86_64, ~15GB free RAM, ~20GB free disk, network
  access to `android.googlesource.com` and `github.com`.
- `sudo` access (installs apt packages).

## Why this isn't a plain `make`

This is a 2016-era Linux 4.4 kernel (Qualcomm Snapdragon 835 / MSM8998,
"msm-4.4" downstream tree). It cannot be built with a modern host GCC
(15.x) or a same-vintage-but-wrong cross toolchain — and the public
`facebookincubator/oculus-linux-kernel` repo is missing a few pieces
that Facebook's internal build system silently provided. Every fix
below is a real, minimal, targeted patch — not a design choice.

### 1. Toolchain: use the vendor's own GCC 4.9, not the host's GCC 15

The kernel's own `build.config.aarch64` names the toolchain it expects:
`CROSS_COMPILE=aarch64-linux-androidkernel-` from
`aarch64-linux-android-4.9`. Building 10-major-versions-old kernel C
against GCC 15 is a losing battle (GCC 14+ made
`-Werror=implicit-function-declaration` unconditional, `-fno-common`
became default in GCC 10+, etc.) — so `build.sh` fetches AOSP's own
prebuilt GCC 4.9 (both aarch64 and the ARM32 compat one, needed for
`CONFIG_COMPAT_VDSO`) instead of fighting the host compiler.

The AOSP prebuilt's `gcc`/`g++` are Python wrapper scripts with a
`#!/usr/bin/python` shebang (Python 2, absent on modern systems) —
`build.sh` patches the shebang to `#!/usr/bin/env python3` (the wrapper
source is python3-compatible).

### 2. Host tools need `-fcommon`

`scripts/dtc` (device tree compiler, built as a *host* tool with the
*host* GCC) fails to link with "multiple definition of `yylloc`" — GCC
10+ defaults to `-fno-common`. Fixed by passing `HOSTCFLAGS="-fcommon"`
to every `make` invocation.

### 3. Missing proprietary `drivers/staging/oculus/internal/`

The public repo's `drivers/staging/oculus/Kconfig` and `Makefile`
reference `drivers/staging/oculus/internal/` (Facebook/Oculus internal,
proprietary, never published — and `.gitignore`d in the tree itself,
confirming it's meant to be provided externally). Two fixes:
- `drivers/staging/oculus/internal/Kconfig` — empty stub, so
  `source "drivers/staging/oculus/internal/Kconfig"` doesn't error.
- Removed `obj-y += internal/` from
  `drivers/staging/oculus/Makefile` — an empty `Makefile` stub there
  produces no `built-in.o`, which breaks the link (`obj-y += internal/`
  expects a real built-in.o to exist).

(These two are **not** in `oculus-kernel-fixes.patch` because
`drivers/staging/oculus/internal/` is `.gitignore`d in the source tree
— `build.sh` recreates the Kconfig stub directly, and the Makefile
line removal *is* captured in the patch since it touches a tracked file.)

### 4. `verity.x509.pem` — proprietary signing cert

`CONFIG_SYSTEM_TRUSTED_KEYS="verity.x509.pem"` points at Oculus's
private dm-verity signing key, which obviously isn't public. Cleared to
`CONFIG_SYSTEM_TRUSTED_KEYS=""` in the `.config` (not a source patch —
apply this to your `kernel.config` before building, `build.sh` does it
automatically).

### 5. Local headers included with `<angle brackets>`, no `-I$(src)`

Several drivers `#include <local_header.h>` (angle brackets, not
quotes) expecting it to resolve via the compiler's include search path
— which only works if the directory is explicitly added. The
directories affected (their `Makefile`s were missing
`ccflags-y += -I$(src)`):

- `drivers/bluetooth` (`btfm_slim.h`)
- `sound/soc/msm` (`device_event.h`)
- `drivers/gpu/msm` (tracepoint header `kgsl_trace.h`, via the standard
  `TRACE_INCLUDE_PATH "."` kernel tracepoint pattern)
- `drivers/media/platform/msm/camera_v2/common`
- `drivers/media/platform/msm/camera_v2/isp`
- `drivers/media/platform/msm/camera_v2/sensor/io`
- `drivers/platform/msm/ipa/ipa_v2`, `ipa_v3` (tracepoint header)
- `drivers/soc/qcom` (tracepoint header)
- `drivers/staging/oculus/mcu/syncboss` (tracepoint header)

All captured in `oculus-kernel-fixes.patch`. If you're applying this to
a *different* `kernel.config` (different driver set enabled), you may
hit the same pattern in other directories — the fix is always
`ccflags-y += -I$(src)` added to that directory's `Makefile`. (A
one-shot autofix loop for this class of error is described at the
bottom of this file.)

### 6. `scripts/Makefile.lib`: dtc `-Wno-simple_bus_reg` / `-Wno-unit_address_format`

`scripts/Makefile.lib` passes `-Wno-simple_bus_reg` and
`-Wno-unit_address_format` to `dtc`, but this tree's own
`scripts/dtc/checks.c` (the dtc built from source, not the system one)
doesn't define those check names — `dtc` refuses to start with
`FATAL ERROR: Unrecognized check name`. Both flags removed (in the
patch).

### 7. Kernel 4.4 targets are for a real device — only relevant if you
also want a QEMU-bootable variant

If you only want the **real Quest 1 kernel**, stop after applying
fixes 1–6 and building with your `kernel.config` as-is. Everything
below is *only* needed to also boot the same source tree under QEMU
(which has no Snapdragon 835 emulation — this is a generic ARM64
"virt" board boot of the same kernel, not a device emulation).

## QEMU-variant-only changes

Starting from the real-device `.config`, add (then run
`make oldconfig`):

```
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_PCI_HOST_GENERIC=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_9P_FS=y
CONFIG_NET_9P=y
CONFIG_NET_9P_VIRTIO=y
```

And disable (real Qualcomm hardware calls that crash/hang under an
emulator with no real TrustZone/RPM firmware — each was root-caused by
booting with `initcall_debug`/`earlycon` and reading the exact crash
site, not guessed):

```
# CONFIG_QCOM_EARLY_RANDOM is not set   # unconditional SMC call in setup_arch() -> UNDEF trap, QEMU has no Qualcomm SCM firmware
# CONFIG_MSM_APM is not set             # references scm_lmh_lock, undefined once QCOM_SCM stubbed out
# CONFIG_QCOM_SCM is not set            # master gate for Qualcomm's proprietary SMC (TrustZone) calls
# CONFIG_MSM_IPC_ROUTER_SMD_XPRT is not set
# CONFIG_MSM_IPC_ROUTER_GLINK_XPRT is not set
```

Disabling `CONFIG_QCOM_SCM` is safe because `include/soc/qcom/scm.h`
already has a proper `#else` branch with no-op inline stubs for
everything except `scm_lmh_lock` (a `mutex`, no stub existed) — the
patch adds `static DEFINE_MUTEX(scm_lmh_lock);` to that `#else` branch
(one-line, in `oculus-kernel-fixes.patch`).

### The `amba-pl011.c` fixes (source patch, in the .patch file)

Two independent driver-level fixes, both needed to get a real login
prompt (not just kernel boot messages) out of the guest:

**1. Carrier-detect never asserted.** QEMU's PL011 UART model never
asserts DCD (no real modem-control lines on a virtual UART), and the
stock `pl011_get_mctrl()` reads the real hardware DCD/DSR/CTS bits —
so `tty_port_block_til_ready()` (core kernel tty layer) blocks forever
on `open()` of the tty (getty, or any respawn inittab entry) whenever
`CLOCAL` isn't already active. The standard fix (used by plenty of
drivers for UARTs with no real modem-control wiring) is to hardcode
DCD/DSR/CTS as always-asserted in `get_mctrl()`.

**2. `ttyAMA0` never registers at all (the actual root cause of "no
shell in QEMU").** This is the bigger one. `arch/arm64/Kconfig` has
`select COMMON_CLK if !ARCH_QCOM` — real Qualcomm hardware gets all
its clocks from `COMMON_CLK_MSM` (this tree's own legacy, non-generic
clock subsystem), so the generic Linux Common Clock Framework core
(`CONFIG_COMMON_CLK`) is deliberately left disabled for `ARCH_QCOM`
kernels. QEMU's `virt` board, however, describes its UART/GPIO/RTC
clock via a plain generic-Linux `fixed-clock` DT binding — which only
gets a driver (`drivers/clk/clk-fixed-rate.c`) when `COMMON_CLK` is
on. Without it, `clk_get()` on these devices returns `-EPROBE_DEFER`
*forever* (nothing will ever register that clock), so
`amba_device_add()` never binds `pl011@9000000` (or `pl061`/`pl031`),
and `/dev/ttyAMA0` never exists — confirmed directly via
`cat /proc/tty/drivers` inside a working sysinit script (no `ttyAMA`
entry at all) and via QEMU's own log:
`of_amba_device_create(): amba_device_add() failed (-517) for /pl011@9000000`.
(`-517` = `-EPROBE_DEFER`.) Meanwhile `earlycon` boot messages still
work fine throughout, because earlycon pokes the UART registers
directly, completely bypassing the tty/amba/clk subsystems — which is
exactly what made this so easy to miss.

Naively enabling `CONFIG_COMMON_CLK` doesn't work either: it and
`COMMON_CLK_MSM` both define the same `clk_prepare`/`clk_enable`/
`clk_get_rate`/etc. symbols, so the two together fail to link
("multiple definition of `clk_prepare`", etc.) — `COMMON_CLK_MSM` on
this kernel version predates the common clock framework and replaces
it outright rather than layering on top of it.

The actual fix has two parts:
- **DTB**: give `pl011@9000000`, `pl061@9030000`, and `pl031@9010000`
  an explicit `arm,primecell-periphid` property (the standard ARM
  PrimeCell IDs, taken straight from each driver's own `amba_id`
  match table: `0x00041011`/`0x00041061`/`0x00041031`). This is a
  real, documented DT override (`drivers/of/platform.c`:
  `of_amba_device_create()`, "Allow the HW Peripheral ID to be
  overridden") that makes `amba_device_add()` skip its
  clock-dependent ID auto-detection read entirely — it stops needing
  a working clock just to identify the device. `build.sh` does this
  with `fdtput` directly on QEMU's dumped DTB (no manual `dts` editing
  needed); the resulting `qemu-kernel/virt.dtb` must be passed to QEMU
  via `-dtb`.
- **Driver**: even with `amba_device_add()` unblocked, the *driver's
  own* `pl011_probe()` still calls `devm_clk_get(&dev->dev, NULL)` for
  the same never-resolvable clock and used to fail probe outright on
  error. The rest of this driver's `clk_prepare`/`clk_enable`/
  `clk_get_rate` call sites already tolerate a `NULL` `struct clk`
  (checked directly in `drivers/clk/msm/clock.c` — `clk_prepare(NULL)`
  and friends just return 0/no-op), so the patch makes probe degrade
  gracefully (`uap->clk = NULL`) instead of bailing out, with a
  hardcoded 24 MHz fallback for `uartclk` (matching QEMU's own
  `clock-frequency` in its DT) so baud-divisor math doesn't operate on
  a zero rate.

Both fixes are in `oculus-kernel-fixes.patch`.

## QEMU invocation + Buildroot rootfs quirk

Boot command (see `run_qemu.sh`, generated by `build.sh`):

```
qemu-system-aarch64 -M virt -cpu cortex-a53 -m 1024 -nographic -smp 1 \
  -kernel qemu-kernel/Image \
  -dtb qemu-kernel/virt.dtb \
  -append "earlycon rootwait root=/dev/vda console=ttyAMA0" \
  -netdev user,id=eth0 -device virtio-net-device,netdev=eth0 \
  -drive file=<buildroot>/output/images/rootfs.ext4,if=none,format=raw,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -device virtio-rng-device \
  -no-reboot
```

Notes on the flags:
- `-dtb qemu-kernel/virt.dtb` is the periphid-patched DT from the
  section above — **without it, `/dev/ttyAMA0` never exists and
  nothing after the kernel's own boot messages is ever visible, no
  matter what else is fixed.**
- `-device virtio-rng-device` is required — the kernel config enables
  the virtio-rng *driver*, but without the actual QEMU device attached,
  `getrandom()`/seedrng can stall waiting for entropy that a
  virtualized guest has almost none of.
- `earlycon` alone (no `keep_bootcon`) is correct now that `ttyAMA0`
  registers properly: earlycon covers the brief window before the real
  console takes over, and the kernel automatically disables the boot
  console once that handoff happens (`bootconsole [uart0] disabled`).
  Do **not** add `keep_bootcon` — it forces the boot console to stay
  registered *alongside* the real one, so every kernel log line prints
  twice for the rest of boot. `keep_bootcon` was a debugging workaround
  from before the DTB/driver fixes below existed (when the real console
  never came up at all); it's no longer needed or wanted.
- Buildroot's stock `/etc/inittab` runs ~11 separate `sysinit` lines;
  under this specific combination (busybox-init 1.36.1 + this kernel),
  transitioning between two of those separate `sysinit` actions would
  hang before `ttyAMA0` was fixed. `build.sh` bundles them into one
  script (`/etc/init.d/rc.sysinit`) instead, which is harmless and
  removes that variable — kept even now that the root cause (below)
  is fixed, since there's no reason to re-introduce a many-line
  inittab once a single-script one is known to work.

Login: `root`, no password, on `ttyAMA0`. Verified working end-to-end
(reached an interactive shell, `whoami`/`uname -a` etc. all functional)
with the DTB fix in place. Run this in a real interactive terminal for
normal terminal behavior.

## Known limitation

QEMU's `virt` machine has **no Snapdragon 835 / MSM8998 emulation**.
The QEMU-bootable variant is the *same kernel source tree*, generically
configured, booting on QEMU's generic ARM64 virtual hardware — none of
the real Quest 1 hardware (Adreno GPU, cameras, sensors, controllers,
display) is present or testable there. This is a hardware-emulation
limitation, not something more kernel config tuning can fix.

## Autofix pattern for the `-I$(src)` class of error (if you enable
different drivers)

If you start from a different `kernel.config` with a different driver
set and hit the same "local header not found" class of error, the
`find_fatal_dirs.py` / `autofix_build.sh` pair used during this build
automates it: parse the build log for `fatal error: ... .h: No such
file`, resolve back through `In file included from ...c:` chains to
find the real originating source directory, and append
`ccflags-y += -I$(src)` to that directory's `Makefile`, then retry.
Not included in this kit (single-purpose to this exact build), but the
technique is described here in case you need it again — reconstructing
it is ~30 lines of Python (regex for the two "In file included from"
forms, direct and continuation-line) plus a bash retry loop.
