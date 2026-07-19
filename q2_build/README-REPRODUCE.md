# Reproducing: Oculus Quest 2 kernel build + QEMU/Buildroot boot

This documents exactly what was done to (1) cross-compile the
`oculus-linux-kernel` (branch `oculus-quest2-kernel-master`) for real
Quest 2 hardware using a supplied `kernel.config`, and (2) get a
QEMU-bootable variant of the same source tree running under
`qemu-system-aarch64` with a Buildroot-built rootfs, verified all the
way through an actual interactive login and shell commands.

Everything below is captured in `build.sh` in this directory — read this
file for the *why*, run `build.sh` for the *how*.

## Files in this kit

- `build.sh` — end-to-end automated build (toolchain, both kernel
  variants, Buildroot, run script). Idempotent-ish: safe to re-run.
- `oculus-kernel-fixes.patch` — the source-tree diff (see below) for
  files git already tracks.
- `kernel.config` — copy of the input config (the real-device config
  you supplied).
- `README-REPRODUCE.md` — this file.

Everything here was built and verified against `oculus-linux-kernel`
commit `6e428607392d72708bc95cb7126768494c6b5ac0` ("Oculus Quest 2
kernel project build: 5220228.2810.150") on
`oculus-quest2-kernel-master`. The patch has been verified to apply
cleanly to a fresh clone of that exact commit; if
`oculus-quest2-kernel-master` has moved on, `git apply` may need
`--3way` or manual conflict resolution.

## What you need before running

- A `kernel.config` file (the real-device `.config` you're starting
  from) in the same directory as `build.sh`.
- Ubuntu/Debian host, x86_64, ~16GB free RAM, ~25GB free disk, network
  access to `android.googlesource.com` and `github.com`.
- `sudo` access (installs apt packages).

## Why this isn't a plain `make`

This is a Linux 4.19 kernel (Qualcomm Snapdragon XR2 / "kona" platform,
codename "hollywood"), built with Clang/LLVM. It sits between the
Quest 1 kit (2016-era Linux 4.4, GCC 4.9, no LLVM at all) and the
Quest 3 kit (Linux 5.10, full GKI/LTO/BTF) in vintage, but shares the
Quest 3 kit's toolchain and `REAL_CC` quirk almost exactly. Where it
differs sharply from *both* is TrustZone/SCM integration — see item 3.

### 1. Toolchain: AOSP's own prebuilt Clang, matching the config exactly

The supplied `kernel.config` names the exact compiler it was generated
with in the `Compiler:` comment at the top of the file and in
`CONFIG_CLANG_VERSION`:
```
Android (8508608, based on r450784e) clang version 14.0.7 ...
```
This is the *same* `clang-r450784e` toolchain the Quest 3 kit uses,
despite the two kernels being three major versions apart — `build.sh`
fetches it the same way, via AOSP gitiles' `+archive` endpoint on the
`master-kernel-build-2022` branch (the exact version is long pruned off
`main`).

`gcc-aarch64-linux-gnu` (from apt) supplies the GNU binutils
(`ar`/`nm`/`objcopy`/`strip`/etc.) that `CROSS_COMPILE=aarch64-linux-gnu-`
still names even though compilation itself goes through Clang with its
integrated assembler (`LLVM_IAS=1`). Unlike Quest 1, no separate 32-bit
ARM toolchain is needed — nothing here references `CROSS_COMPILE_ARM32`.

### 2. `Error: No compiler specified` — `REAL_CC` isn't optional

Same issue, same fix, as the Quest 3 kit: this tree's top-level
`Makefile` does, unconditionally, `CC := $(REAL_CC)` — written for
Google's Kleaf/Bazel build, which computes `REAL_CC` internally. A
plain `make LLVM=1` leaves `REAL_CC` (and therefore `CC`) empty, and
every compiler invocation fails with `Error: No compiler specified`.
Fixed by exporting `REAL_CC=clang` on every invocation.

### 3. `smc` instruction → `Internal error: undefined instruction: 0` under QEMU

This is the one genuinely new problem in this kernel, not seen on
Quest 1 or Quest 3. Booting the real-device kernel unmodified under
`qemu-system-aarch64 -M virt` panics **before any console output at
all** past the SCM/PSCI banner, with a `swapper/0`/PID 1 crash and all
registers zeroed.

Root-caused with `gdb-multiarch` attached to QEMU's gdbstub (`-s -S`,
plus `nokaslr` on the cmdline so the ELF's link-time symbol addresses
match the running kernel): a breakpoint on `do_undefinstr` (from
`arch/arm64/kernel/traps.c`) shows the fault PC is inside
`is_scm_armv8()` in `drivers/soc/qcom/scm.c`, right at:
```
smc  #0x0
```
QEMU's `virt` machine, without `-machine virt,secure=on` **and** real
EL3 firmware loaded via `-bios`, does not implement a general Secure
Monitor — it only special-cases the handful of standard PSCI function
IDs (which is why `psci: SMC Calling Convention v1.0` prints fine
earlier in boot). Any *other* SMC — like this vendor SCM probe —
UNDEFINED-traps immediately, because there's no real EL3 to route it
to. (Adding `secure=on` doesn't fix this either: it changes the
`-kernel` direct-boot path to expect real EL3 firmware, and the kernel
never gets to boot at all.)

Two different early-boot callers hit this, both via
`drivers/soc/qcom/scm.c`'s `is_scm_armv8()` → `smc`:

- `scm_mem_protection_init()` (`early_initcall`, gated by
  `CONFIG_QCOM_QHEE_ENABLE_MEM_PROTECTION`) — cleanly disabled for the
  QEMU variant via `scripts/config -d QCOM_QHEE_ENABLE_MEM_PROTECTION`
  (`build.sh` step 6). No other code depends on it; this one's a plain
  `.config` change, no patch needed.
- `qtee_shmbridge_init()` (`early_initcall` in
  `drivers/soc/qcom/qtee_shmbridge.c`, unconditional whenever
  `CONFIG_QTEE_SHM_BRIDGE=y`) — **cannot** be disabled the same way.
  `techpack/display/config/konadisp.conf` force-`export`s
  `CONFIG_DRM_MSM_SDE=y` (and several sibling display configs) as plain
  Makefile variables whenever `CONFIG_ARCH_KONA=y`, completely
  bypassing Kconfig/`.config` — so `techpack/display/msm/sde/sde_kms.o`
  (which calls `qtee_shmbridge_allocate_shm()` etc. directly, no `#if`
  guard) is *always* compiled for this SoC family, on both variants,
  regardless of what `.config` says. `include/soc/qcom/qtee_shmbridge.h`
  also has no `#else` stub implementations for when the feature is
  off — the whole driver was written assuming it's always present on
  this chip. Disabling `CONFIG_QTEE_SHM_BRIDGE` therefore cascades into
  broken links across the display driver, `QSEECOM`, `HDCP_QSEECOM`,
  `QCOM_SMCINVOKE`, `QTI_CRYPTO_TZ`, and the Adreno GPU driver
  (`QCOM_KGSL`, whose frequency governor also calls straight into
  `qtee_shmbridge_*`) — a huge, unwanted amount of real hardware to rip
  out just to silence one early SMC probe.

  Fixed instead with a **3-line source patch** (in
  `oculus-kernel-fixes.patch`) that gates the one `smc`-issuing call in
  `qtee_shmbridge_init()` on `of_machine_is_compatible("qcom,kona")`.
  Real Quest 2 hardware's device tree root `compatible` includes
  `"qcom,kona"` (confirmed directly in
  `arch/arm64/boot/dts/oculus/kona-oculus.dts`), so **real-device
  behavior is completely unchanged** — the check is true, the function
  runs exactly as before. QEMU's `virt` board reports
  `compatible = "linux,dummy-virt"`, so the check is false there and
  the function returns immediately, before ever reaching the `smc`.
  This is the only place in this kit where a source patch (rather than
  a `.config` change) was required to get the QEMU variant to boot —
  everywhere else, real-hardware-only options could just be turned off.

### 4. Local headers included with `<angle brackets>`, no `-I$(src)`

Same class of issue as the Quest 1 and Quest 3 kernels (shared
lineage): several drivers `#include <local_header.h>` (angle brackets)
or `#include <../relative/path.h>`, expecting it to resolve via the
compiler's include search path, or requiring the *parent* directory's
own headers to be reachable without `-I$(src)` on that directory.
Errors like `fatal error: 'local_header.h' file not found`. Fixed
either by adding `ccflags-y += -I$(src)` to that directory's
`Makefile`/`Kbuild`, or by quoting an offending
`<../relative/path.h>` include:

- `drivers/clk/qcom/Makefile`, `techpack/display/pll/Makefile`,
  `techpack/camera/drivers/cam_req_mgr/Makefile`,
  `techpack/camera/drivers/cam_sensor_module/cam_cci/Makefile` —
  missing `-I$(src)` (`pll_trace.h`, `cam_req_mgr_core.h`,
  `cam_cci_dev.h` not found)
- `drivers/thermal/thermal_core.c` — `<../base/base.h>` →
  `"../base/base.h"`
- `drivers/power/supply/bq27xxx_battery.c` — `<power_supply.h>` →
  `"power_supply.h"` (there's a driver-local
  `drivers/power/supply/power_supply.h` shadowing the real
  `linux/power_supply.h`; angle brackets picked up neither correctly)

### 5. `drivers/staging/qcacld-3.0/Kbuild` — relative-vs-absolute `srctree` symlink

This Kbuild redirects the (very long) WLAN driver source path through
a short symlink (`/tmp/qcacld-3.0`) to avoid command-line overflows:
```makefile
PATCH_LONG_PATH := $(srctree)/drivers/staging/qcacld-3.0
PATCH_SYMLINK := $(shell ln -nsf $(PATCH_LONG_PATH) $(PATCH_SHORT_PATH))
```
When building from the top of the tree (no `O=` out-of-tree build
directory), `$(srctree)` is `.` — a *relative* path. `ln -s`  stores
that target string verbatim, so the resulting symlink at
`/tmp/qcacld-3.0` points at `./drivers/staging/qcacld-3.0` interpreted
relative to `/tmp` itself (i.e. a broken link to
`/tmp/drivers/staging/qcacld-3.0`), not the kernel tree. This makes the
Kbuild's own `$(wildcard ...)` existence check for its WLAN defconfig
fragment fail, and the subsequent `include $(WLAN_DEFCONFIG_FILE)`
fatally errors with "No rule to make target". Fixed with one-line
change to make the symlink target absolute:
```makefile
PATCH_LONG_PATH := $(abspath $(srctree)/drivers/staging/qcacld-3.0)
```
(A separate, cosmetic-only `$(warning "WLAN defconfig file ... not
found!")` still prints during the build even after this fix — that
particular check independently double-prepends `$(srctree)` on top of
the now-absolute `$(WLAN_DEFCONFIG_FILE)`, so its own wildcard test
still misfires. It's harmless: it's a `$(warning)`, not an `$(error)`,
and the actual `include` line that matters resolves correctly and the
WLAN driver builds and links fine.)

### 6. `crypto-qti-platform.h` stub — `const` mismatch (latent, harmless on real hardware)

`drivers/soc/qcom/crypto-qti-platform.h`'s `#else` branch (used when
`CONFIG_QTI_CRYPTO_TZ` is *off*) declares a stub
`crypto_qti_tz_raw_secret()` missing both `const` on its first
parameter and a `static inline` (just `static`, an ODR/multiple-definition
risk in any translation unit that includes the header more than once).
The real (`CONFIG_QTI_CRYPTO_TZ=y`) declaration two lines above has
`const`. Since the caller in `crypto-qti-common.c` always passes a
`const u8 *`, building with the `#else` stub active fails with
`-Werror,-Wincompatible-pointer-types-discards-qualifiers`. This was
found while investigating whether `QTI_CRYPTO_TZ` could be disabled for
the QEMU variant (see item 3) — it turned out that path wasn't taken in
the end (both variants keep `QTI_CRYPTO_TZ=y`, matching the supplied
`kernel.config`, so the buggy `#else` branch is never actually compiled
here), but the header bug is real and independent of that decision, so
the fix is included in the patch regardless.

## QEMU-variant-only changes

Starting from the real-device `.config`, add (then run
`make olddefconfig`):

```
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_MENU=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_RTC_CLASS=y
CONFIG_RTC_DRV_PL031=y
```
and disable the two hardware-only options that don't have a working
QEMU equivalent and would otherwise hang/crash boot before any console
comes up (see item 3 above for why `QCOM_QHEE_ENABLE_MEM_PROTECTION`
crashes; the other four are the same class of real-SMC/RPM-only code
paths the Quest 1 kit also had to turn off for its own, unrelated,
kernel):
```
# CONFIG_QCOM_QHEE_ENABLE_MEM_PROTECTION is not set
# CONFIG_QCOM_EARLY_RANDOM is not set
# CONFIG_MSM_APM is not set
# CONFIG_MSM_PM is not set
# CONFIG_MSM_IPC_ROUTER_SMD_XPRT is not set
# CONFIG_MSM_IPC_ROUTER_GLINK_XPRT is not set
```
That's it — **everything else stays exactly as supplied**, including
`CONFIG_QSEECOM`, `CONFIG_QTEE_SHM_BRIDGE`, `CONFIG_QCOM_KGSL` (Adreno
GPU), `CONFIG_QCOM_SCM`, etc. all remaining `=y`. None of those needed
to be turned off once the one crashing `smc` call (item 3) was fixed at
the source level instead of via Kconfig — a deliberately much smaller
`.config` diff than it first looked like it would need.

### Why *not* to pre-dump and pass a `-dtb` (unlike the Quest 1 kit)

Same reasoning as the Quest 3 kit: `arch/arm64/Kconfig` selects
`COMMON_CLK` unconditionally here too (no `ARCH_QCOM` exclusion,
confirmed by `CONFIG_COMMON_CLK=y` already present in the supplied
real-device `kernel.config`), so QEMU's generic `fixed-clock` DT
binding for `pl011`/`pl061`/`pl031` works with zero DTB patching.
Confirmed by the boot log showing
`9000000.pl011: ttyAMA0 at MMIO 0x9000000 ... is a PL011 rev1` and
`console [ttyAMA0] enabled` with QEMU's own auto-generated DTB, no
`-dtb` flag at all.

### Benign warnings you'll see in the QEMU boot log

A handful of `WARN_ON`s fire during boot and are expected — they're the
kernel noticing it isn't running on real Qualcomm hardware, not boot
failures (boot continues normally past every one of them):
- `WALT: Invalid cpu topology!!` — the WALT scheduler's cluster-topology
  code expects real per-CPU capacity/cluster data from a Qualcomm DT;
  QEMU's generic `virt` CPU topology doesn't provide it.
- `Unknown SOC ID!` (`drivers/soc/qcom/socinfo.c`) — no real SMEM
  (`qcom,smem`) region exists under QEMU to read the hardware SoC ID
  from, so it falls back to dummy values and warns.
- `Error: Driver 'arm-smmu' is already registered, aborting...` — a
  duplicate-registration warning from an SMMU node dedup quirk in this
  tree's IOMMU probing; harmless, nothing depends on a second instance.
- Assorted `Failed to create IPC log*` / `unable to create logging
  context` / `unable to create debugfs` lines — vendor debug-log
  facilities failing to allocate because their expected parent debugfs
  nodes (also hardware/SoC-init-gated) don't exist; purely
  observability, no functional impact.

## QEMU invocation + Buildroot rootfs quirk

Boot command (see `build/run_qemu.sh`, generated by `build.sh`):

```
qemu-system-aarch64 -M virt -cpu cortex-a53 -m 1024 -nographic -smp 1 \
  -kernel qemu-kernel/Image \
  -append "earlycon rootwait root=/dev/vda console=ttyAMA0" \
  -netdev user,id=eth0 -device virtio-net-device,netdev=eth0 \
  -drive file=<buildroot>/output/images/rootfs.ext4,if=none,format=raw,id=hd0 \
  -device virtio-blk-device,drive=hd0 \
  -device virtio-rng-device \
  -no-reboot
```

Notes on the flags:
- No `-dtb` — see above.
- `-device virtio-rng-device` is required — the kernel config enables
  the virtio-rng *driver*, but without the actual QEMU device attached,
  `getrandom()`/seedrng can stall waiting for entropy a virtualized
  guest has almost none of.
- Buildroot's stock `/etc/inittab` runs many separate `sysinit` lines;
  the same busybox-init hang seen on the Quest 1 and Quest 3 kits
  (transitioning between separate `sysinit` actions hangs before a full
  console is up) applies here too — `build.sh` bundles them into one
  script (`/etc/init.d/rc.sysinit`) instead, same fix as those kits.

Login: `root`, no password, on `ttyAMA0`. Verified end-to-end with an
actual interactive session (via `expect`, driving a real PTY — not just
reaching the login prompt): logged in, then ran `whoami` (→ `root`),
`id`, `uname -a` (confirms `4.19.325` and the exact Clang/LLD build
string), and a marker `echo`, all executed live inside the booted
guest, followed by a clean `poweroff`.

## Known limitation

QEMU's `virt` machine has **no Snapdragon XR2 emulation**. The
QEMU-bootable variant is the *same kernel source tree*, generically
configured, booting on QEMU's generic ARM64 virtual hardware — none of
the real Quest 2 hardware (Adreno GPU, cameras, sensors, controllers,
display, TrustZone/QSEE) is present or testable there, and the boot log
warnings listed above are the kernel noticing exactly that. This is a
hardware-emulation limitation, not something more kernel config tuning
can fix.
