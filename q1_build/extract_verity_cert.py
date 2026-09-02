#!/usr/bin/env python3
"""Extract the real /system dm-verity signing certificate from a live
device's boot partition, so CONFIG_SYSTEM_TRUSTED_KEYS can point at a real
cert instead of being blanked out.

Why this exists: certs/verity.x509.pem is proprietary and was never
published in this repo (Meta's internal build injects it). Without it,
CONFIG_SYSTEM_TRUSTED_KEYS has to be blanked, which leaves the kernel's
trusted keyring empty. That's not cosmetic - drivers/md/dm-android-verity.c
verifies /system's dm-verity signature against that keyring unconditionally
(the unlocked-bootloader bypass only covers malformed verity *metadata*,
not a failed signature check), so an empty keyring makes /system's verity
target creation fail outright and init hangs forever waiting for it to
mount - silently, no panic, nothing in pstore.

The certificate itself is public (it's the public half of Meta's signing
keypair, not the private key) - AVB1/legacy Android boot signing appends
it, DER-encoded, right after the boot image's kernel+ramdisk. This script
pulls it out of a real device's boot_b (or boot_a) dump, which you can get
yourself via, on a device with an unlocked bootloader and ADB root:

    adb root
    adb shell dd if=/dev/block/bootdevice/by-name/boot_b of=/data/local/tmp/boot_b.img
    adb pull /data/local/tmp/boot_b.img

Usage:
    python3 extract_verity_cert.py --boot-img /path/to/boot_b.img -o verity.x509.pem

Optionally cross-check against a real vmlinux (if you have one, e.g. from
a kernel debug-symbol package) to confirm the same cert bytes are compiled
into its trusted keyring - the strongest available confirmation this is
actually the right cert, short of a device to test-boot against:

    python3 extract_verity_cert.py --boot-img boot_b.img --vmlinux vmlinux -o verity.x509.pem
"""
import argparse
import base64
import struct
import sys


def find_boot_signature_der(boot_bytes: bytes) -> bytes:
    """Locate and extract the DER X.509 certificate from an AVB1-style
    boot signature block. The signature block is a DER SEQUENCE containing
    an INTEGER (format version) followed by the certificate SEQUENCE
    itself; it's appended directly after the page-aligned kernel+ramdisk
    content in header_version=0 boot images with no dedicated AVB2 footer.
    """
    # Standard Android boot image header (v0): magic(8) + 10x uint32 + ...
    if boot_bytes[:8] != b"ANDROID!":
        raise ValueError("not a standard Android boot image (missing ANDROID! magic)")

    (kernel_size, _kernel_addr, ramdisk_size, _ramdisk_addr,
     _second_size, _second_addr, _tags_addr, page_size,
     _header_version, _os_version) = struct.unpack_from("<10I", boot_bytes, 8)

    def pages(n):
        return (n + page_size - 1) // page_size

    content_end = page_size + pages(kernel_size) * page_size + pages(ramdisk_size) * page_size

    # Find the outer DER SEQUENCE (0x30 0x82 <2-byte length>) starting at
    # or shortly after content_end - some images may have a few bytes of
    # padding before it, so scan forward a little rather than assuming
    # it's at the exact boundary.
    search_start = content_end
    search_window = boot_bytes[search_start:search_start + 64]
    offset = search_window.find(b"\x30\x82")
    if offset == -1:
        raise ValueError(
            "no DER SEQUENCE found near the expected boot-signature offset "
            f"({search_start:#x}) - this image may not have an AVB1-style "
            "boot signature, or the header/page-size math is off for this device"
        )
    sig_start = search_start + offset

    outer_len = struct.unpack_from(">H", boot_bytes, sig_start + 2)[0]
    sig_block = boot_bytes[sig_start:sig_start + 4 + outer_len]

    p = 4
    assert sig_block[p] == 0x02, "expected INTEGER (format version) after outer SEQUENCE"
    int_len = sig_block[p + 1]
    p += 2 + int_len

    assert sig_block[p:p + 1] == b"\x30", "expected certificate SEQUENCE"
    tag_len_byte = sig_block[p + 1]
    if tag_len_byte & 0x80:
        nbytes = tag_len_byte & 0x7F
        length = int.from_bytes(sig_block[p + 2:p + 2 + nbytes], "big")
        hdr_len = 2 + nbytes
    else:
        length = tag_len_byte
        hdr_len = 2
    cert_der = sig_block[p:p + hdr_len + length]
    if len(cert_der) != hdr_len + length:
        raise ValueError("certificate SEQUENCE runs past the signature block - offsets are wrong")
    return cert_der


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--boot-img", required=True, help="path to a boot_a/boot_b dump (raw partition or boot.img)")
    ap.add_argument("--vmlinux", help="optional: real vmlinux to cross-check the cert is in its compiled-in keyring")
    ap.add_argument("-o", "--output", default="verity.x509.pem", help="output PEM path (default: verity.x509.pem)")
    args = ap.parse_args()

    with open(args.boot_img, "rb") as f:
        boot_bytes = f.read()

    cert_der = find_boot_signature_der(boot_bytes)
    print(f"extracted {len(cert_der)}-byte DER certificate from boot signature block")

    pem_body = base64.encodebytes(cert_der).decode("ascii")
    pem = "-----BEGIN CERTIFICATE-----\n" + pem_body + "-----END CERTIFICATE-----\n"
    with open(args.output, "w") as f:
        f.write(pem)
    print(f"wrote {args.output}")

    if args.vmlinux:
        with open(args.vmlinux, "rb") as f:
            vmlinux_bytes = f.read()
        idx = vmlinux_bytes.find(cert_der)
        if idx != -1:
            print(f"cross-check OK: identical cert bytes found in vmlinux's compiled-in keyring at offset {idx:#x}")
        else:
            print(
                "WARNING: cert bytes not found verbatim in the given vmlinux - "
                "double check this is the vmlinux for the same build as --boot-img",
                file=sys.stderr,
            )


if __name__ == "__main__":
    main()
