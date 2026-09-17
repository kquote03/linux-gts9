# Fedora WiFi, sleep and boot reliability — September 2026

Investigation on the SM-X716B, 2026-09-14–15. Fedora is the active target.
The Pixel 6 hotspot reboot and extended-sleep reboot remain open until their
specific reproductions pass; the findings below do not establish their cause.

## Firmware and throughput

The live tablet booted Samsung `WLAN.HSP.2.0.c11-00358` from the initramfs,
then reloaded community `WLAN.HSP.1.1-03125` during the panel's platform PM
test. All three installed rootfs files (AMSS, board-2, M3) differed from the
selected Samsung overlay. This was deployed-artifact drift, not evidence
that the Samsung calibration bytes needed changing.

Restored the complete committed set to `/usr/lib/firmware/ath11k/WCN6855/hw2.1`.
After a reboot, panel recovery and subsequent deep-sleep resumes all loaded
HSP 2.0. The firmware quirk remains at its automatic `-1` setting.

Three 25,000,000-byte HTTPS downloads on a 5 GHz, 20 MHz VHT network measured
14,727,939, 14,444,221 and 14,087,904 bytes/s (117.8, 115.6 and 112.7 Mbit/s).
Both RX chains measured approximately -41 dBm, with VHT NSS 2. These are
internet-transfer measurements, not controlled Android comparisons or a
measurement of maximum radio throughput. The preceding 2.4 GHz test still
showed asymmetric per-chain RSSI; the 5 GHz result must not be generalized
to every band/AP. No firmware crash was captured during these transfers.

### Research and remaining hotspot work

Read the previous calibration and Hexagon forensic record before changing
firmware: `wifi-samsung-calibration.md` and
`wifi-samsung-calibration-forensics.md`. The matched Samsung firmware is
signed; speculative edits to calibration or executable bytes are not a fix.

The existing workaround skips legacy `WMI_VDEV_SET_WMM_PARAMS_CMDID` sends.
The MU-EDCA path in `ath11k_mac_op_conf_tx_mu_edca()` still sends the same
command with a different type. Upstream introduced this path to configure
802.11ax MU-EDCA, testing on HSP 1.1 firmware, not this Samsung HSP 2.0
build. This makes it a concrete hotspot investigation lead, not a confirmed
Pixel crash diagnosis. No broader command suppression has been added.
See the [upstream MU-EDCA patch](https://kernel.googlesource.com/pub/scm/linux/kernel/git/stable/stable-queue/+/refs/tags/v6.17.12/releases/6.12.58/wifi-ath11k-add-support-for-mu-edca.patch).

Also checked upstream regulatory and suspend paths. The historical
[WCN6855 country-command crash fix](https://lists.infradead.org/pipermail/ath11k/2022-January/002593.html)
distinguishes current-country from init-country commands; this distinction
is already in the pinned tree. `ath11k_core_resume_default()` also restores
the country code after reinitialization. Do not blindly apply old suspend
or regulatory patches based on chipset name alone.

The next hotspot test must record firmware identity, band/channel, security,
WMI activity and any RDDM dump over an independent working USB connection.
Test Pixel 6 WPA2, WPA3 and mixed mode separately. Compare the dump's Q6-SFR
PC with the known legacy-WMM fault at `0x017be7d0` before changing the quirk.

### Preventing a repeat

`scripts/verify-wifi-firmware.py` compares all four selected files, including
regdb, against the firmware overlay. It checks directories, gzip/newc or
LZ4 initramfs archives, and Fedora ext4 images via read-only `debugfs`.
It rejects `firmware-2.bin` overrides, incomplete/mismatched sets and
conflicting `/lib` and `/usr/lib` archive copies. It never extracts archive
paths onto the host filesystem.

Fedora and initramfs builds verify staging; boot packaging checks both
ramdisks; rootfs packaging checks its input; raw-image deployment checks the
actual Fedora image before writing it. Other distributions retain their own
deployment layout. Fedora staging replaces the generic `hw2.1 -> hw2.0`
symlink with a board-specific directory, without modifying generic hw2.0.
If selecting community firmware for an A/B, regenerate the overlay and
rebuild the rootfs and initramfs together.

## Deep sleep and resume

The actual default is `s2idle [deep]`, contrary to the old README's s2idle
claim. Deep sleep remains the requirement; it has not been replaced with
s2idle.

The old kernel's boot log contains a concrete warning:

```
i2c i2c-3: Transfer while suspended
Workqueue: events_unbound sm5714_usbpd_cc_watch_work
```

The recurring USB-C CC watcher and initial resync were queued on
`system_dfl_wq`, and the driver has no PM callback canceling them. A
deferrable timer does not freeze work during suspend. Both CC workers now
use `system_freezable_wq`, including the recurring requeue; the OTG pulse
worker is unchanged. The kernel's
[workqueue documentation](https://docs.kernel.org/core-api/workqueue.html#flags)
specifies that freezable work is drained before suspend and cannot begin
again until thaw. This corrects the demonstrated I2C access race, but does
not by itself prove that it caused every reported reboot.

The installed kernel remains build #78 until the new boot image is flashed.
With the corrected firmware and userspace, the same boot survived an
approximately 11-minute sleep and several shorter cycles. A timed test
returned after about 23 seconds with an unchanged boot ID. The new resume
service ran after `systemd-suspend.service` completed, then started one SSC
recovery attempt. The user's subsequent manual wake also worked normally.
USB gadget enumeration did not return reliably after the timed test; WiFi
remained usable. Do not infer a system crash solely from loss of USB SSH.

Still required: install and validate the CC-worker kernel fix, repeated deep
sleep with WiFi connected/disconnected, charging/unplugged, and overnight
tests with retained crash evidence. PPS RTC keepalive and battery drain must
be checked separately. No extended-sleep reliability claim is made yet.

## Boot and sensor recovery

Before the changes, sensor recovery ran for 120.152 seconds and was ordered
before the display manager. `graphical.target` took 147.753 seconds. The
X11 ownership fix already used its corrected timer and took about 35 ms;
it was not the measured multi-minute delay.

The documented PDR maps were absent from both the repository's staged
`qcom-sm8550` directory and the tablet's matching firmware directory.
Recovered `adspr.jsn`, `adsps.jsn`, `adspua.jsn` and `cdspr.jsn` from this
tablet's read-only `/vendor/firmware_mnt/image`, keeping their contents
unchanged. `pd-mapper` now stays active. Its
[source](https://raw.githubusercontent.com/andersson/pd-mapper/master/pd-mapper.c)
discovers JSON maps beside the selected remoteproc firmware; merely having
them on a separately mounted vendor partition was insufficient. Extraction
and Fedora builds now reject missing maps.

Discovery starts from a boot timer and does not gate the desktop. A single
bounded worker checks PD-map availability, restarts sensorspd once, probes
SSC, and restarts SensorProxy only after a real accelerometer measurement.
ADSP startup now requires completion of panel recovery instead of sleeping
25 seconds and hoping that recovery finished.

The old hooks under `/etc/systemd/system-sleep` were not executed by Fedora.
[systemd-sleep's implementation](https://raw.githubusercontent.com/systemd/systemd/main/src/sleep/sleep.c)
uses its compiled `SYSTEM_SLEEP_PATH`; Fedora's `/usr/lib/systemd/system-sleep`
was empty. Replaced the hooks with `gts9wifi-resume.service`, wanted by and
ordered before `sleep.target`, with `StopWhenUnneeded=yes` and recovery in
`ExecStop`. Reverse stop ordering runs recovery after the sleep transaction
finishes. Discovery, its boot timer and sensorspd conflict with **sleep.target**,
which precedes kernel suspend; **suspend.target** is reached after resume
and was the wrong cancellation boundary. The measured timed test confirmed
the new ordering without job cancellation or a blocking sleep hook.

After a reboot with these firmware/boot changes, `graphical.target` reached
35.037 seconds in userspace (38.084 seconds including kernel startup).
Only optional SSC recovery remained failed. Its FastRPC server reports
unsupported methods and registry-directory operations; restoring PD maps
does not solve that separate SSC implementation gap. Full sensor bring-up
is not claimed.

## Validation and artifacts

- Kernel Image, DTB and modules built successfully; boot bundle packaged
  successfully with both firmware checks passing.
- Python packaging tests cover matching sets, stale/missing files, API2
  overrides, conflicting archive paths, truncated input and firmware read
  directly from a modified ext4 image.
- Shell syntax and Nix syntax checked; systemd units verified on Fedora.
- The stale original Fedora directory fails verification; the rebuilt
  rootfs and initramfs agree on the selected Samsung set.
- Private evidence and reproducible build logs are under `out/reliability/`.
  Raw dumps and journals are not committed.

For a reproduction, run as root on the tablet:

```
systemd-run --unit=x716-wifi-capture /usr/libexec/gts9wifi-diagnostics \
    /var/log/gts9wifi-diagnostics/hotspot 600
```

The helper records boot/firmware identity, link statistics, power state,
journals and pstore, follows the kernel log, and saves devcoredumps while
watching. Keep its output private: dumps may contain network traffic.
Flashing still requires the backup and confirmation procedure in
`boot-strategy.md`; a rebuilt rootfs image is not a reason to erase the
tablet's current user data.
