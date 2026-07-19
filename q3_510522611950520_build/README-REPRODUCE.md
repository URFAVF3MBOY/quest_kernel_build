# Reproducing: Oculus Quest 3 kernel build + QEMU/Buildroot boot

This documents exactly what was done to (1) cross-compile the
`oculus-linux-kernel` (branch `oculus-quest3-kernel-master`) for real
Quest 3 hardware using a supplied `kernel.config`, and (2) get a
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
commit `8f32bdea05abf85dd10d6202963f7e9bdc55c717` ("Oculus Quest 3
kernel project build: 5227074.3810.520") on
`oculus-quest3-kernel-master`. The patch has been verified to apply
cleanly to a fresh clone of that exact commit; if
`oculus-quest3-kernel-master` has moved on, `git apply` may need
`--3way` or manual conflict resolution.

`build.sh` now pins the clone to a specific commit (`KERNEL_COMMIT` near
the top of the script) rather than the branch tip, currently
`2ec81fa7af4875987bb74ba132661dfb4ade999a` ("Oculus Quest 3 kernel project
build: 5105226.11950.520", 2025-07-08). The patch-apply step falls back
automatically (`--3way`, then per-file exclusion) if hunks no longer match
at whatever commit is pinned — see "Commit-specific gap" below for the one
exclusion needed at this particular commit.

## What you need before running

- A `kernel.config` file (the real-device `.config` you're starting
  from) in the same directory as `build.sh`.
- Ubuntu/Debian host, x86_64, ~16GB free RAM, ~25GB free disk, network
  access to `android.googlesource.com` and `github.com`.
- `sudo` access (installs apt packages).

## Why this isn't a plain `make`

This is a Linux 5.10 Android Common Kernel (GKI-style, Qualcomm
Snapdragon XR2 Gen 2 / "anorak" platform, `msm-waipio` lineage),
built with Clang/LLVM rather than GCC. Compared to the Quest 1 kernel
(2016-era Linux 4.4, GCC 4.9), the toolchain and build-system quirks
are almost entirely different — this is a from-scratch investigation,
not a copy of the Quest 1 fixes.

### 1. Toolchain: AOSP's own prebuilt Clang, matching the config exactly

The supplied `kernel.config` names the exact compiler it was generated
with in `CONFIG_CC_VERSION_TEXT`:
```
"Android (8508608, based on r450784e) clang version 14.0.7 ..."
```
`build.config.common` in the kernel tree also references
`CLANG_PREBUILT_BIN=prebuilts-master/clang/host/linux-x86/clang-r416183b/bin`
— a **different**, generic/stale version. The config's own
`CONFIG_CC_VERSION_TEXT` is authoritative (it's what the config was
literally built with), so `build.sh` fetches `clang-r450784e`
specifically.

AOSP's `android.googlesource.com/platform/prebuilts/clang/host/linux-x86`
repo prunes old Clang versions off the tip of its default branch as new
ones ship — `clang-r450784e` is no longer present on `main`/`main-kernel`.
It's still reachable via one of the repo's long-lived
`master-kernel-build-YYYY` branches (in this case
`master-kernel-build-2022`, which matches the toolchain's ~Feb 2022
vintage). Gitiles' `+archive` endpoint (`.../+archive/refs/heads/<branch>/<path>.tar.gz`)
fetches just that one subdirectory as a tarball instead of the whole
(huge, many-version) repo history.

`gcc-aarch64-linux-gnu` (from apt) supplies the GNU binutils
(`ar`/`nm`/`objcopy`/`strip`/etc.) that `CROSS_COMPILE=aarch64-linux-gnu-`
still names even though compilation itself goes through Clang with its
integrated assembler (`LLVM_IAS=1`).

### 2. `Error: No compiler specified` — `REAL_CC` isn't optional

This tree's top-level `Makefile` does, unconditionally:
```makefile
CC := $(REAL_CC)
```
This is written for Google's Kleaf/Bazel-based kernel build system,
which computes `REAL_CC` internally and passes it in. Building with a
plain `make` invocation (no Kleaf) the normal way for this era of
kernel — `LLVM=1` — is not enough on its own: `REAL_CC` is empty unless
you set it, which silently makes `CC` empty too, and every compiler
invocation fails downstream with `Error: No compiler specified` (from
`scripts/gcc-version.sh`) and syntax errors while parsing `Kconfig`
(from the now-brokenly-invoked `clang-version.sh`). Fixed by exporting
`REAL_CC=clang` (or passing it on the `make` command line) on every
invocation — `build.sh` does this throughout.

### 3. Build silently dies during `LTO vmlinux.o` (OOM, not a real error)

The supplied `kernel.config` has `CONFIG_LTO_CLANG_FULL=y` (plus
`CONFIG_CFI_CLANG=y`, which requires LTO). Full LTO links the *entire*
kernel as one compilation unit in a single `ld.lld` process — on a
machine with ~15GB RAM this gets OOM-killed partway through with **no
error message at all** in the build log (just `Terminated` /
`make: *** [Makefile:1414: vmlinux] Error 143`, or `Killed` / `Error
137` depending on exactly how the kernel reclaims memory). This looks
like a build-system bug but is not — it's purely a host memory
constraint.

Fixed by switching to ThinLTO (`CONFIG_LTO_CLANG_THIN=y`,
`CONFIG_LTO_CLANG_FULL` disabled) via `scripts/config`. ThinLTO
partitions the link into independent per-module summaries and codegen
units with bounded memory per thread, and produces an equally valid
(still LTO-optimized) `vmlinux`. This is a `.config` change (in
`build.sh`, not the patch) — if you have significantly more than
~15GB RAM available, full LTO may work for you unmodified.

### 4. `Failed to generate BTF for vmlinux` — missing `pahole`

Once the LTO step gets past linking, `CONFIG_DEBUG_INFO_BTF=y` (implied
by this GKI-style config) needs `pahole` (from the `dwarves` package)
to generate BTF type info from DWARF debug info. Not installed by
default on a plain Ubuntu host. Fixed by `apt install dwarves` (added
to `build.sh`'s dependency list).

### 5. Local headers included with `<angle brackets>`, no `-I$(src)`

Same class of issue as the Quest 1 kernel (this codebase shares that
lineage): several drivers `#include <local_header.h>` (angle brackets)
or `#include <../relative/path.h>` (relative-with-angle-brackets, e.g.
`thermal_core.c` including `<../base/base.h>`), expecting it to resolve
via the compiler's include search path, or requiring the *parent*
directory's own headers to be reachable without `-I$(src)` on that
directory. Errors like `fatal error: 'local_header.h' file not found`.
The directories/files affected (all fixed either by adding
`ccflags-y += -I$(src)` to that directory's `Makefile`/`Kbuild`, or by
changing an offending `<../path.h>` include to `"../path.h"`):

- `drivers/platform/msm/Makefile`, `drivers/tty/serial/Makefile` —
  missing `-I$(src)`
- `drivers/thermal/thermal_core.c`,
  `drivers/block/mtip32xx/mtip32xx.c`,
  `drivers/input/touchscreen/st/fts_lib/ftsFlash.c`,
  `drivers/input/touchscreen/st/fts_lib/ftsTest.c`,
  `drivers/scsi/pcmcia/nsp_cs.c` — `<../relative/path.h>` → `"../relative/path.h"`
- `drivers/staging/qcacld-3.0/Kbuild`,
  `include/trace/events/trace_msm_pil_event.h`,
  `include/trace/events/trace_msm_ssr_event.h`,
  `include/trace/hooks/{binder,block,logbuf,mm,mmc_core,typec,ufshcd}.h`,
  `kernel/sched/walt/walt_cfs.c`,
  `tools/perf/util/libunwind/{arm64,x86_32}.c` — same pattern

All captured in `oculus-kernel-fixes.patch`. If you're applying this to
a *different* `kernel.config` (different driver set enabled), you may
hit the same pattern in other directories not listed here — the fix is
always either `ccflags-y += -I$(src)` in that directory's
`Makefile`/`Kbuild`, or quoting a `<../relative/path.h>` include.

Unlike the Quest 1 build, this tree has **no missing proprietary
directories** — every subdirectory referenced by
`drivers/staging/oculus/Makefile` (`hzos_ext/`, `langdon/`, `pdfu/`,
`usbvdm/`, `stp/`, `mcu/`, `vd6281/`, `tests/`, `include/`) is present
and populated in the public repo, so no stub `Kconfig`/`Makefile` was
needed here.

## Commit-specific gap: `eureka.dtb` build at commit `2ec81fa7af4875987bb74ba132661dfb4ade999a`

Unlike the reference commit `8f32bdea05abf85dd10d6202963f7e9bdc55c717` this
kit was originally verified against, `eureka-panel.dtsi` at commit
`2ec81fa7af4875987bb74ba132661dfb4ade999a` ("Oculus Quest 3 kernel project
build: 5105226.11950.520") unconditionally `#include`s two files under a
`../unknown7/` directory (`unknown7-dsi-panel-jdi-nvt-dsc-2392x2560-90hz-video.dtsi`,
`unknown7-dsi-panel-sharp-nvt-dsc-2392x2560-90hz-video.dtsi`) that do not
exist anywhere in the public repo at this commit, at the branch tip, or at
the reference commit — confirmed via the GitHub API/raw content, not
inferred. At the reference commit, `eureka-panel.dtsi` didn't reference
`unknown7/` at all, so these two `#include` lines (for a JDI/Sharp
NVT-DDIC DSC 90Hz panel variant) were added to Meta's internal tree at some
point after that, without the corresponding proprietary panel-timing files
ever being published to the public mirror — an upstream export gap in this
specific snapshot, not a build-system bug.

Since the missing files are proprietary panel timing data (not something
to reconstruct or guess at), the fix in `oculus-kernel-fixes.patch` removes
the two `#include` lines plus the two `&dsi_..._nvt_..._dsc_video { ... }`
override blocks and their two entries in the `display_panels` list. The
other 5 real, already-public Quest 3 panel variants (BOE, JDI, JDI
experimental, Sharp, Sharp experimental) are untouched and still build into
`eureka.dtb`. If you're building a different commit, check whether this
same gap applies — it will show up as `fatal error: '../unknown7/...' file
not found` while building `dtbs`.

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

That's it — **no other real-hardware-only options needed to be
disabled** for a working QEMU boot. This is a much smaller diff than
the Quest 1 QEMU config, for two reasons specific to this kernel:

- `CONFIG_QCOM_SCM` builds as a **module** (`m`) here, not built-in.
  Something (`ARM_SMMU`/`QCOM_MDT_LOADER`) still selects it, so
  `scripts/config -d QCOM_SCM` doesn't stick through `olddefconfig` —
  but since it's a module and this minimal Buildroot rootfs never has a
  modules directory or runs `modprobe`, it's simply never loaded.
  Nothing calls into real Qualcomm SMC/TrustZone firmware at boot, so
  there's no crash to work around.
- Everything else Qualcomm-specific that's actually **built in**
  (`=y`) — `QCOM_SMEM`, `QCOM_GDSC`, `QCOM_WATCHDOG_*`, etc. — is gated
  behind matching a Qualcomm-specific compatible string in the device
  tree via normal platform-driver probing. QEMU's `virt` board DTB has
  no such nodes, so these drivers simply never probe (no error, no
  crash) instead of failing partway through like Quest 1's did.

### Why *not* to pre-dump and pass a `-dtb` (unlike the Quest 1 kit)

The Quest 1 kit dumps QEMU's DTB once (`qemu-system-aarch64 -M
virt,dumpdtb=...`), patches it with `fdtput` to fix an AMBA PrimeCell
clock-probing issue specific to *that* kernel, and passes it back in
via `-dtb` on every boot. **Do not do this for Quest 3** — it actively
breaks boot here.

Root-caused by attaching `gdb-multiarch` to QEMU's built-in gdbstub
(`-s -S`) and inspecting the actual PC: the kernel hangs *completely
silently* (zero console output, not even the earlycon "Booting Linux"
banner) inside `setup_machine_fdt()`'s `while (true) cpu_relax();`
error loop, in `arch/arm64/kernel/setup.c`. That loop is entered
whenever `fixmap_remap_fdt()` returns `NULL` — which happens if the FDT
magic doesn't check out *or* `fdt_totalsize() > MAX_FDT_SIZE`
(`SZ_2M`, i.e. 2MB, in `arch/arm64/include/asm/boot.h`).

Reading physical guest memory directly at the FDT's load address (via
gdb's `monitor xp` passthrough to QEMU's HMP monitor) showed the actual
problem: when QEMU boots with an explicit `-dtb <file>` *and*
`-append`/virtio devices, it doesn't just pass your file through — it
re-opens and re-grows the FDT in memory (via `fdt_open_into()`,
injecting `/chosen/bootargs`, `kaslr-seed`, `rng-seed`, etc.), and the
regrown tree ends up **~2.1MB**, just over this kernel's 2MB
`MAX_FDT_SIZE` limit. (This limit doesn't exist for the *original*
pre-dumped file, whose own header says exactly 1MB — it's specific to
what QEMU rebuilds it into at actual boot time.) The kernel's `pr_crit`
explaining exactly this ("Error: invalid device tree blob...") never
appears anywhere because it fires *before* any console (even earlycon)
has been set up — `setup_machine_fdt()` runs before `setup_arch()`'s
earlycon initialization.

The fix is simply to **not pass `-dtb` at all** — QEMU then generates
its own appropriately-sized DTB matching the actual requested machine
config directly in guest memory (no file round-trip, no growth-related
size issue), and — since this kernel doesn't have Quest 1's
`ARCH_QCOM`-excludes-`COMMON_CLK` problem (see below) — that's already
everything the AMBA/virtio devices need to probe correctly. Simpler
than the Quest 1 kit in every respect, once you know not to carry that
kit's DTB-patching step over.

### Why the Quest 1 `COMMON_CLK`/AMBA-periphid fix isn't needed here

Quest 1's `arch/arm64/Kconfig` had `select COMMON_CLK if !ARCH_QCOM`,
so `CONFIG_COMMON_CLK` was compiled out on a real-hardware config,
which broke QEMU's generic `fixed-clock` DT binding for `pl011`/`pl061`/
`pl031` and required a whole DTB-periphid-override + driver-NULL-clk
workaround. This kernel's `arch/arm64/Kconfig` selects `COMMON_CLK`
**unconditionally** (no `ARCH_QCOM` exclusion) — confirmed directly in
the source and in the supplied `kernel.config` (`CONFIG_COMMON_CLK=y`
is already set even in the real-device config). So the generic clock
framework is present, QEMU's `fixed-clock` nodes get a driver, and
`amba_device_add()` for `pl011`/`pl061`/`pl031` succeeds with zero
patching needed — confirmed by the boot log showing
`9000000.pl011: ttyAMA0 at MMIO 0x9000000 ... is a PL011 rev1` and
`printk: console [ttyAMA0] enabled` with no DTB changes at all.

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
  `getrandom()`/seedrng can stall waiting for entropy that a
  virtualized guest has almost none of.
- Buildroot's stock `/etc/inittab` runs ~11 separate `sysinit` lines;
  the same busybox-init hang seen on the Quest 1 build (transitioning
  between two separate `sysinit` actions hangs before a full console is
  up) applies here too — `build.sh` bundles them into one script
  (`/etc/init.d/rc.sysinit`) instead, same fix as the Quest 1 kit.

Login: `root`, no password, on `ttyAMA0`. Verified end-to-end with an
actual interactive session (via `expect`, driving a real PTY — not just
reaching the login prompt): logged in, then ran `whoami` (→ `root`),
`id`, `uname -a`, and a marker `echo`, all executed live inside the
booted guest, followed by a clean `poweroff`.

## Known limitation

QEMU's `virt` machine has **no Snapdragon XR2 Gen 2 emulation**. The
QEMU-bootable variant is the *same kernel source tree*, generically
configured, booting on QEMU's generic ARM64 virtual hardware — none of
the real Quest 3 hardware (Adreno GPU, cameras, sensors, controllers,
display) is present or testable there. This is a hardware-emulation
limitation, not something more kernel config tuning can fix.
