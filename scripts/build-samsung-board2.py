#!/usr/bin/env python3
"""
Build an ath11k board-2.bin carrying this device's own Samsung factory WiFi
calibration (bdwlan.elf, pulled from the tablet's eMMC).

The generic community board-2.bin from linux-firmware does not fit this
specific board -- one RX chain sits at the noise floor and throughput is
capped around 6-9 Mbit/s. This device's own factory calibration does fit
(~5x throughput, no dead chain, NSS 2). It needs Samsung's version-matched
firmware alongside it (amss20.bin + Samsung's m3.bin), and the kernel's
ath11k_mac_skip_legacy_wmm_params() quirk, which auto-activates on the
WLAN.HSP.2.0 build. See docs/wifi-samsung-calibration.md.

board-2.bin is a flat TLV container:
  magic "QCA-ATH11K-BOARD\0" padded to 20 bytes, then a sequence of
  {u32 id LE, u32 len LE, data[ALIGN(len,4)]} IEs. id 0 (ATH11K_BD_IE_BOARD)
  wraps nested NAME (sub-id 0) + DATA (sub-id 1) sub-IEs per board variant;
  ath11k linear-scans the NAMEs for an exact match and hands the following
  DATA to firmware verbatim.

This takes the community board-2.bin and replaces, in place, only the DATA
of the entry whose NAME is the exact string ath11k builds for this device
(subsystem-device=0108, qmi-chip-id=2, qmi-board-id=255) with Samsung's
bdwlan.elf *file*, wrapper included -- every other entry, and every IE
length, stays byte-identical. Prints the result's sha256 and re-parses it
to confirm the swap.

Usage:
  scripts/build-samsung-board2.py [<community board-2.bin>] [<out board-2.bin>]

Defaults:
  in : buildroot/firmware-overlay/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin
       (must already be the community file -- run fetch-ath11k-firmware.sh
       with WIFI_CAL=community first if it has been overwritten)
  out: same path (in-place)
Source calibration:
  vendor-firmware-dump/firmware/qca6490/bdwlan.elf
"""
import hashlib
import os
import struct
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEFAULT_B2 = os.path.join(
    REPO, "buildroot/firmware-overlay/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin"
)
SS_BDF = os.path.join(REPO, "vendor-firmware-dump/firmware/qca6490/bdwlan.elf")

MAGIC = b"QCA-ATH11K-BOARD"
HDRLEN = 20
BD_IE_BOARD = 0
BD_IE_BOARD_NAME = 0
BD_IE_BOARD_DATA = 1
TARGET_NAME = (
    "bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,"
    "subsystem-device=0108,qmi-chip-id=2,qmi-board-id=255"
)


def align4(n):
    return (n + 3) & ~3


def ie(ie_id, body):
    return struct.pack("<II", ie_id, len(body)) + body + b"\x00" * (align4(len(body)) - len(body))


def iter_ies(buf, off, end):
    while off + 8 <= end:
        i, ln = struct.unpack_from("<II", buf, off)
        off += 8
        if off + ln > end:
            return
        yield i, ln, off, buf[off:off + ln]
        off += align4(ln)


def main():
    b2_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_B2
    out_path = sys.argv[2] if len(sys.argv) > 2 else b2_path

    orig = open(b2_path, "rb").read()
    if orig[:len(MAGIC)] != MAGIC:
        sys.exit("%s is not a board-2.bin (bad magic)" % b2_path)
    ss = open(SS_BDF, "rb").read()
    if ss[:4] != b"\x7fELF":
        sys.exit("%s is not an ELF" % SS_BDF)

    out = bytearray(orig[:HDRLEN])
    patched = 0
    for ie_id, ie_len, off, data in iter_ies(orig, HDRLEN, len(orig)):
        if ie_id != BD_IE_BOARD:
            out += ie(ie_id, data)
            continue
        names, subs = [], []
        for sid, slen, soff, sdata in iter_ies(orig, off, off + ie_len):
            if sid == BD_IE_BOARD_NAME:
                names.append(sdata.rstrip(b"\x00").decode("ascii", "replace"))
            subs.append((sid, sdata))
        if TARGET_NAME in names:
            subs = [(sid, ss if sid == BD_IE_BOARD_DATA else sd) for sid, sd in subs]
            patched += 1
        out += ie(BD_IE_BOARD, b"".join(ie(sid, sd) for sid, sd in subs))

    if patched != 1:
        sys.exit(
            "expected exactly one entry named %r, patched %d -- is the input the "
            "community board-2.bin?" % (TARGET_NAME, patched)
        )

    open(out_path, "wb").write(bytes(out))
    print("wrote %s" % out_path)
    print("  size   %d (community %d, %+d)" % (len(out), len(orig), len(out) - len(orig)))
    print("  sha256 %s" % hashlib.sha256(bytes(out)).hexdigest())

    # re-parse to confirm the target entry now carries bdwlan.elf verbatim
    for ie_id, ie_len, off, _ in iter_ies(bytes(out), HDRLEN, len(out)):
        if ie_id != BD_IE_BOARD:
            continue
        nm, dt = [], None
        for sid, slen, soff, sdata in iter_ies(bytes(out), off, off + ie_len):
            if sid == BD_IE_BOARD_NAME:
                nm.append(sdata.rstrip(b"\x00").decode("ascii", "replace"))
            elif sid == BD_IE_BOARD_DATA:
                dt = sdata
        if TARGET_NAME in nm:
            ok = dt == ss
            print("  verify entry '%s...' DATA == bdwlan.elf: %s" % (TARGET_NAME[:40], ok))
            if not ok:
                sys.exit("re-parse mismatch")
            break


if __name__ == "__main__":
    main()
