#!/usr/bin/env python3
"""Pre-flight: will this kernel's vendor modules still load?

WHY THIS EXISTS
---------------
Quest 3 boots with CONFIG_MODVERSIONS=y and ~270 PREBUILT vendor modules
(/vendor_dlkm/lib/modules): wlan, dwc3_msm, usb_f_gsi, clk_qcom, qcom_scm,
arm_smmu ... Each embeds, in its __versions section, the CRC it expects for
every kernel symbol it imports. Those CRCs are computed from the symbol's
prototype AND the layout of every type it transitively references.

So changing a struct that an exported symbol's prototype touches silently
changes that symbol's CRC, the prebuilt module refuses to load, the device
loses critical hardware, and the kernel does not boot. There is no error
message you can see - it just falls back to the stock kernel.

This is not hypothetical. Two measured examples from this project:

  * CONFIG_CONSOLE_POLL=y (pulled in by CONFIG_KGDB_SERIAL_CONSOLE) adds
    three fields to the MIDDLE of struct tty_operations and struct
    uart_ops -> every tty/serial symbol's CRC changes -> no boot.
  * Adding a ->udc_poll member to struct usb_gadget_ops changed 11 gadget
    symbol CRCs (usb_function_register, usb_ep_autoconfig,
    config_ep_by_speed, ...) -> usb_f_gsi.ko will not load -> no boot.

Note the ANDROID_KABI_RESERVE(1)/(2) slots in struct uart_ops: this tree is
built to a stable-KABI contract on purpose. Respect it, or use the reserved
slots.

USAGE
-----
  # normal use, before every flash/boot - reads vendor-kabi.json.gz:
  ./check-vendor-kabi.py

  # regenerate that baseline from the device (booted, adb rooted). Only
  # needed if the headset's firmware changes:
  ./check-vendor-kabi.py --refresh

Exits non-zero if any vendor module would fail to load.

The committed baseline is vendor-kabi.json.gz - just the symbol->CRC table
extracted from every module's __versions section (a few hundred KB). The
.ko files themselves are a throwaway cache: 59MB of device binaries that
are re-fetchable in a minute and tied to one exact firmware build, so they
are NOT kept.
"""

import argparse
import glob
import gzip
import json
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODDIR = os.path.join(HERE, "vendor-modules")     # transient cache
BASELINE = os.path.join(HERE, "vendor-kabi.json.gz")  # the committed artifact
DEFAULT_SYMVERS = os.path.join(HERE, os.pardir, "oculus-linux-kernel",
                               "vmlinux.symvers")

# struct modversion_info { unsigned long crc; char name[64 - sizeof(long)]; }
ENT = 64


def module_required_crcs(path):
    """Return {symbol: crc} from a .ko's __versions section."""
    out = subprocess.run(["readelf", "-x", "__versions", path],
                         capture_output=True, text=True).stdout
    raw = bytearray()
    for line in out.splitlines():
        parts = line.split()
        # readelf -x rows look like: 0xADDR  W0 W1 W2 W3  ....ascii....
        if len(parts) >= 6 and parts[0].startswith("0x"):
            for word in parts[1:5]:
                if len(word) == 8:
                    raw += bytes.fromhex(word)
    want = {}
    for off in range(0, len(raw) // ENT * ENT, ENT):
        crc = struct.unpack_from("<Q", raw, off)[0]
        name = raw[off + 8:off + ENT].split(b"\0")[0].decode(errors="replace")
        if name:
            want[name] = crc & 0xFFFFFFFF
    return want


def kernel_provided_crcs(symvers):
    have = {}
    with open(symvers) as f:
        for line in f:
            fields = line.split()
            if len(fields) >= 2:
                have[fields[1]] = int(fields[0], 16) & 0xFFFFFFFF
    return have


def fetch_modules(adb):
    os.makedirs(MODDIR, exist_ok=True)
    listing = subprocess.run(
        [adb, "shell", "ls /vendor_dlkm/lib/modules/*.ko"],
        capture_output=True, text=True).stdout.split()
    if not listing:
        sys.exit("No modules listed. Is the device booted and 'adb root' done?")
    print(f"Pulling {len(listing)} vendor modules into {MODDIR} ...")
    for i, remote in enumerate(listing, 1):
        remote = remote.strip()
        if not remote.endswith(".ko"):
            continue
        local = os.path.join(MODDIR, os.path.basename(remote))
        subprocess.run([adb, "pull", remote, local],
                       capture_output=True, text=True)
        if i % 50 == 0:
            print(f"  {i}/{len(listing)}")
    print(f"Done: {len(glob.glob(os.path.join(MODDIR, '*.ko')))} modules cached.")


def device_fingerprint(adb):
    """Identify the firmware these modules came from."""
    def prop(name):
        r = subprocess.run([adb, "shell", "getprop", name],
                           capture_output=True, text=True)
        return r.stdout.strip()
    return {
        "build_fingerprint": prop("ro.build.fingerprint"),
        "vendor_fingerprint": prop("ro.vendor.build.fingerprint"),
        "kernel": prop("ro.boot.kernel.version") or "",
    }


def export_baseline(moddir, path, meta=None):
    """Boil the .ko cache down to the only thing we actually check."""
    mods = {}
    for ko in sorted(glob.glob(os.path.join(moddir, "*.ko"))):
        want = module_required_crcs(ko)
        if want:
            mods[os.path.basename(ko)] = want
    with gzip.open(path, "wt") as f:
        json.dump({"meta": meta or {}, "modules": mods}, f,
                  indent=0, sort_keys=True)
    n = sum(len(v) for v in mods.values())
    print(f"wrote {path}: {len(mods)} modules, {n} symbol requirements, "
          f"{os.path.getsize(path)} bytes")


def load_baseline(path):
    with gzip.open(path, "rt") as f:
        d = json.load(f)
    return d.get("modules", {}), d.get("meta", {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symvers", default=DEFAULT_SYMVERS,
                    help="vmlinux.symvers from the kernel build")
    ap.add_argument("--modules", default=MODDIR,
                    help="directory of cached vendor .ko files")
    ap.add_argument("--refresh", action="store_true",
                    help="re-pull the .ko files from the device and rebuild "
                         "vendor-kabi.json.gz (only needed if the headset "
                         "firmware changes)")
    ap.add_argument("--adb", default="adb",
                    help="adb binary to use")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if args.refresh:
        meta = device_fingerprint(args.adb)
        fetch_modules(args.adb)
        export_baseline(args.modules, BASELINE, meta)

    if not os.path.exists(args.symvers):
        sys.exit(f"No symvers at {args.symvers}\n"
                 "Build the kernel first (it is produced by MODPOST).")
    if not os.path.exists(BASELINE):
        sys.exit(f"No baseline at {BASELINE}.\n"
                 "Run once with --refresh (device booted, adb root).")
    mods, meta = load_baseline(BASELINE)

    # The baseline describes the DEVICE'S FIRMWARE, not our build. It stays
    # valid until the headset takes an OTA, after which it silently
    # describes modules that are no longer installed - the same stale-input
    # trap that a mismatched boot.img caused. Warn loudly if we can tell.
    fp = meta.get("build_fingerprint") or "(unrecorded)"
    print(f"baseline firmware: {fp}")
    if not meta:
        print("  WARNING: this baseline predates provenance stamping.\n"
              "           Re-run with --refresh to record which firmware it "
              "describes.")
    else:
        live = subprocess.run([args.adb, "shell", "getprop",
                               "ro.build.fingerprint"],
                              capture_output=True, text=True).stdout.strip()
        if live and live != fp:
            print("  *** STALE BASELINE ***")
            print(f"  device is now: {live}")
            print("  The headset firmware changed; these CRCs describe the "
                  "OLD vendor modules.")
            print("  Re-run with --refresh, and re-pull boot.img too.")
        elif live:
            print("  matches the attached device")

    have = kernel_provided_crcs(args.symvers)
    print(f"kernel provides {len(have)} versioned symbols "
          f"({os.path.relpath(args.symvers, HERE)})")
    print(f"checking {len(mods)} vendor modules against "
          f"{os.path.basename(BASELINE)}\n")

    broken = {}
    for mod, want in sorted(mods.items()):
        bad = [(n, int(w), have[n]) for n, w in want.items()
               if n in have and have[n] != int(w)]
        if bad:
            broken[mod] = bad

    if not broken:
        print("PASS - every vendor module's CRCs match this kernel.")
        print("(Symbols a module imports from ANOTHER module are not checked;")
        print(" only what vmlinux exports.)")
        return 0

    print(f"FAIL - {len(broken)} module(s) would refuse to load:\n")
    culprits = {}
    for mod, bad in sorted(broken.items()):
        print(f"  {mod}: {len(bad)} CRC mismatch(es)")
        if args.verbose:
            for n, w, h in bad:
                print(f"      {n:<42} wants 0x{w:08x} ours 0x{h:08x}")
        for n, _, _ in bad:
            culprits[n] = culprits.get(n, 0) + 1

    print("\nMost common mismatched symbols (these point at the struct you changed):")
    for n, cnt in sorted(culprits.items(), key=lambda kv: -kv[1])[:15]:
        print(f"  {cnt:>3} module(s)  {n}")
    print("\nFix: do not alter any struct reachable from these symbols'")
    print("prototypes. Use a separate exported variable/function, or one of")
    print("the ANDROID_KABI_RESERVE slots, instead of adding a struct member.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
