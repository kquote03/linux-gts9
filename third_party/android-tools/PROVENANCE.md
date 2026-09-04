# Provenance: vendored Android boot-image tooling

These files are not packaged in nixpkgs, so they're vendored directly rather
than fetched at build time (unlike the mainline kernel and uniLoader, which
are large/active upstreams pinned via `scripts/fetch-*.sh`). Each file below
is an unmodified copy from the pinned upstream commit.

## mkbootimg (`mkbootimg/`)

- Upstream: `https://android.googlesource.com/platform/system/tools/mkbootimg`
- Pinned commit: `d2bb0af5ba6d3198a3e99529c97eda1be0b5a093` (2025-03-02)
- License: Apache-2.0 (AOSP platform default; no per-repo `LICENSE` file is
  present upstream, consistent with other AOSP `platform/system/tools/*`
  projects — see https://source.android.com/setup/start/licenses).
- Files copied verbatim: `mkbootimg.py`, `unpack_bootimg.py`,
  `repack_bootimg.py`, `gki/generate_gki_certificate.py` (a dependency of
  `mkbootimg.py`, needed for GKI boot image certification support).

## avb (`avb/`)

- Upstream: `https://android.googlesource.com/platform/external/avb`
- Pinned commit: `c5066a96caa7bf4150c0a8cc8cc14ab81733fdc7` (2026-08-19)
- License: Apache-2.0 (see vendored `LICENSE` file, copied verbatim).
- Files copied verbatim: `avbtool.py`, `LICENSE`.

## Verification

Both tools run standalone under plain `python3` (stdlib only, no extra
dependencies) — confirmed inside `shell.nix`:

```
python3 third_party/android-tools/mkbootimg/mkbootimg.py --help
python3 third_party/android-tools/avb/avbtool.py --help
```
