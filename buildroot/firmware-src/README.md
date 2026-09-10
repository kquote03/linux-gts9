# firmware-src

Source inputs for `scripts/fetch-ath11k-firmware.sh`, kept here rather
than fetched at build time so the default build is fully offline and
byte-deterministic.

- **`board-2.bin.wcn6855-community`** — the upstream `linux-firmware`
  `ath11k/WCN6855/hw2.0/board-2.bin` (sha256
  `9287fa8d14d915892666b03e9403135875d08371fd1438d2c6d9fe96ae71cf68`,
  as of linux-firmware `main`, 2026-09). `scripts/build-samsung-board2.py`
  uses it as the container base: it replaces only this device's own
  exact-match board entry's DATA with `bdwlan.elf`, leaving all other
  entries byte-identical. Refresh it from upstream with
  `WIFI_CAL=community` + copy, if linux-firmware ever changes it.

See `docs/wifi-samsung-calibration.md`.
