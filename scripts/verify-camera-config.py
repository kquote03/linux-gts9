#!/usr/bin/env python3
"""Reject a kernel build that silently dropped camera support before flashing.

Checks a `scripts/build-mainline-kernel.sh` output directory for the two
camera Kconfig symbols, the two built driver modules, and (via `dtc`) that
the compiled board DTB actually wires up &camss/&cci0/&cci1 and both sensor
nodes -- not just that the devicetree *source* looks right (kernel/dts/
sm8550-samsung-x716b.dts can compile fine while still, say, losing a node to
a bad `status` override resolved only after full preprocessing).
"""
import argparse
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent
BOARD_DTB = "sm8550-samsung-x716b.dtb"
CONFIG_SYMBOLS = ("CONFIG_VIDEO_HI1337_GTS9", "CONFIG_VIDEO_DW9808_VCM")
MODULE_STEMS = ("hi1337_gts9", "dw9808_vcm")
REQUIRED_DT_NODES = ("camss", "cci@ac15000", "cci@ac16000", "camera@21", "camera@20")


def check_config(config_path):
    if not config_path.is_file():
        raise ValueError(f"{config_path}: not found -- build the kernel first")
    text = config_path.read_text()
    lines = set(text.splitlines())
    for symbol in CONFIG_SYMBOLS:
        if f"{symbol}=m" in lines or f"{symbol}=y" in lines:
            continue
        raise ValueError(f"{config_path}: {symbol} is not built (=m/=y) -- "
                          "camera Kconfig symbols were dropped by config merge/dependency resolution")


def check_modules(modules_dir):
    if not modules_dir.is_dir():
        raise ValueError(f"{modules_dir}: not found -- run modules_install first")
    for stem in MODULE_STEMS:
        matches = [*modules_dir.rglob(f"{stem}.ko"), *modules_dir.rglob(f"{stem}.ko.zst")]
        if not matches:
            raise ValueError(f"{modules_dir}: no {stem}.ko(.zst) found -- "
                              "driver did not build or was not installed")


def check_dtb(dtb_path):
    if not dtb_path.is_file():
        raise ValueError(f"{dtb_path}: not found -- build the board DTB first")
    try:
        result = subprocess.run(["dtc", "-O", "dts", "-I", "dtb", str(dtb_path)],
                                 capture_output=True, text=True, check=True)
    except FileNotFoundError:
        raise ValueError("dtc not found on PATH -- run inside nix-shell (shell.nix)")
    except subprocess.CalledProcessError as error:
        raise ValueError(f"{dtb_path}: dtc failed to decompile: {error.stderr}")
    decompiled = result.stdout
    for node in REQUIRED_DT_NODES:
        if node not in decompiled:
            raise ValueError(f"{dtb_path}: missing expected node/label containing {node!r}")
    # A node can be *present* but left disabled -- camss/cci0/cci1 must all
    # actually be enabled, not just exist in the compiled tree.
    for marker in ("isp@acb7000", "cci@ac15000", "cci@ac16000"):
        start = decompiled.index(marker)
        end = decompiled.index("\n\t\t};", start)
        block = decompiled[start:end]
        if 'status = "okay"' not in block:
            raise ValueError(f"{dtb_path}: {marker} is not status=\"okay\" in the compiled DTB")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-out", type=Path, default=REPO / "out/kernel",
                        help="build-mainline-kernel.sh output directory (default: out/kernel)")
    args = parser.parse_args()
    config_path = args.kernel_out / ".config"
    modules_dir = args.kernel_out / "modules-out"
    dtb_path = args.kernel_out / "arch/arm64/boot/dts/qcom" / BOARD_DTB

    check_config(config_path)
    check_modules(modules_dir)
    check_dtb(dtb_path)
    print(f"{args.kernel_out}: camera Kconfig symbols, modules, and DTB wiring all present")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"camera config verification failed: {error}")
