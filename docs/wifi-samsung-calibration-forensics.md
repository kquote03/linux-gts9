# WiFi Samsung-calibration investigation — raw forensic notes

Deep-analysis output from the investigation summarised in
`wifi-samsung-calibration.md`. Kept for the record: it has byte-level
detail (RDDM coredump layout, the faulting Hexagon instruction and its
NULL-pointer chain, the board-2.bin container reverse-engineering, the
XOR-checksum derivation) that the summary doc deliberately compresses.
These were produced by analysis agents during the session; lightly
edited, not otherwise curated. If the firmware bug is ever pursued
upstream / with Qualcomm, start here.

The 16 MB RDDM coredump itself and the extracted firmware segments are
**not** committed (they lived in a scratch dir); recapture with the
crash-safe tmpfs harness described in `wifi-samsung-calibration.md` if
needed.

---

## Part 1 — board-2.bin / BDF format + the 8 BDF-only crash tests

# Why Samsung's `bdwlan.elf` crashes mainline ath11k's WCN6855 firmware — round 4

Device: Samsung Galaxy Tab S9 5G (SM-X716B), SM8550, WCN6855/QCA6490 (PCI `17cb:1103`,
subsystem `17cb:0108`), ath11k `wcn6855 hw2.1`.
Evidence base: `/tmp/bdf/live-test6-verbose-dmesg.log` (722 lines, `ath11k` `debug_mask=0x1074`),
the four dumped vendor firmware files, the shipped community firmware set, mainline
`ath11k` source, Samsung's downstream `cnss2` source, and the sibling Tab S9 Ultra notes.

---

## 0. Verdict, up front

**The crash is not a container, wrapper, transport, size, format-generation or checksum
problem. All of those are now positively excluded with evidence.** What is left is the
*content* of ~60 config-region fields, and the fatal one cannot be named from open
information — Qualcomm's BDF field schema is not public.

But the investigation produced two things that materially change the situation:

1. **A hard, previously-unknown fact: the two firmware stacks are different major
   branches.** The device's stock WLAN firmware is `WLAN.HSP.2.0.c11-00358`; the
   community firmware this port runs is `WLAN.HSP.1.1-03125-…_LITE-3.6510.41`. Samsung's
   `bdwlan.elf` was authored against the 2.0 branch. (§2)
2. **The one experiment that could actually work has never been run.** Round 3's
   "version-matched pair" test (attempt #1) swapped `amss.bin` and `board-2.bin` but
   **left the WLAN.HSP.1.1 `m3.bin` in place**. Samsung's own `m3.bin` differs from the
   community one in **184,137 of 262,144 payload bytes (70 %)**. That test ran a 2.0-branch
   AMSS against a 1.1-branch M3 co-processor image — which is a far better explanation for
   why it hung the whole AP than "the BDF is wrong". (§3)

So the honest answer is neither "fixable by patching bytes" nor "provably impossible".
It is: **the remaining decisive experiments are cheap, safe (with the harness in §9), and
have not been done.** Four candidate files and a crash-loop-proof test harness are built
and ready (§8, §9).

---

## 1. What the verbose dmesg actually proves

### 1.1 The crash is on the **final** BDF chunk, i.e. during firmware-side processing

`ath11k_qmi_load_file_target_mem()` (`kernel/linux/drivers/net/wireless/ath/ath11k/qmi.c`,
lines 2297–2409) logs in this order per chunk:

* `"bdf download req fixed addr type %d"` — **before** `qmi_send_request()` (qmi.c:2365)
* `"bdf download request remaining %i"` — **after** a successful `qmi_txn_wait()` +
  `QMI_RESULT_SUCCESS_V01` check (qmi.c:2398)

and sets `req->end = 1` only on the last chunk (qmi.c:2340–2341).

In the log, for `bdf_type 1` (board data):

| what | count |
|---|---|
| `bdf download req fixed addr type 1` (sends) | **10** (log L679…L697) |
| `bdf download request remaining` after those | **9** (L680…L696) |

9 × 6144 + 4604 = **59 900** = the exact byte size of
`vendor-firmware-dump/firmware/qca6490/bdwlan.elf`. So chunks 1–9 were acknowledged
`SUCCESS`; the **10th send — the one carrying `end = 1` — never got a response.**

* L697 `[443.977523]` last send
* L698 `[444.300333]` `boot notify status reason MHI_CB_EE_RDDM` → **+322.8 ms**
* L699 `firmware crashed: MHI_CB_EE_RDDM`
* L701 `[454.131817]` `failed to wait board file download request: -110` (the 10 s
  `ATH11K_QMI_WLANFW_TIMEOUT_MS` expiring against a dead firmware)

**Conclusion:** every byte arrived and was accepted. The firmware died inside its own
`end = 1` handler — the point at which it assembles, validates and applies the board data.
No host-side, protocol-side or container-side step failed.

### 1.2 Everything upstream of that worked, including on the same file

* `chip_id 0x2 chip_family 0xb board_id 0xff soc_id 0x400c0210` (L321) — `board_id = 0xFF`
  and `chip_id & 0x10 == 0`, which is exactly the condition under which Samsung's own
  `cnss2` selects the plain, no-suffix, non-"g" `bdwlan.elf`
  (`cnss2/qmi.c:702-711`, `CHIP_ID_GF_MASK 0x10` at `cnss2/qmi.c:29`). The variant choice
  made in earlier rounds is **confirmed correct**.
* regdb (`bdf_type 4`) from the *same* `board-2.bin` downloaded in 4 chunks and completed
  cleanly (L655–L664). The container and the QMI path are fine.
* Name matching picked the intended entry by exact string match (L675–L677), and ath11k's
  `ELFMAG` sniff correctly classified it as `bdf_type 1` (qmi.c:2419–2421, log L678).

### 1.3 MHI RDDM is what a firmware **assert** looks like, not only a data abort

`MHI_CB_EE_RDDM` is an execution-environment change to RAM-dump mode. In Qualcomm WLAN
firmware that is entered from the generic `ERR_FATAL` path, which is reached both by CPU
exceptions *and* by explicit `Assertion … failed` calls — the community `amss.bin` is full
of them (`Asserted in:0x%x:0x%x, line#%d`, `Assertion failed: %s, function %s, file %s,
line %d.`). So the crash signature does **not** distinguish "the firmware faulted on bad
data" from "the firmware deliberately rejected the file". Both look identical from the host.
This is important: it means we cannot infer *severity* from the signature.

---

## 2. NEW: the two stacks are different major firmware branches

```
community amss.bin (running today, per log L322 and the file itself):
  QC_IMAGE_VERSION_STRING=WLAN.HSP.1.1-03125-QCAHSPSWPL_V1_V2_SILICONZ_LITE-3.6510.41

Samsung amss20.bin (this unit's stock firmware, dumped from its own eMMC):
  QC_IMAGE_VERSION_STRING=WLAN.HSP.2.0.c11-00358-QCAHSPSWPL_V1_V2_SILICONZ-1.44583.17.50066.50
```

Not just a different build number — a different release train (`HSP.1.1` vs `HSP.2.0`), and
the community one is additionally a `_LITE` (feature-reduced) build while Samsung's is the
full `SILICONZ`.

`amss20.bin` is the file `cnss2` picks for this exact silicon: `pci.c:52`
`#define FW_V2_FILE_NAME "amss20.bin"`, selected when
`device_version.major_version == FW_V2_NUMBER` (`main.h:57`, value 2) — and this device
reports `pci tcsr_soc_hw_version major 2 minor 16` (log L269). `qca6490/` comes from
`QCA6490_PATH_PREFIX` (`pci.c:44`), matching the dump's directory layout exactly. The dump
is therefore genuine and complete for the stock stack:

```
qca6490/amss20.bin   WLAN.HSP.2.0.c11   5,496,832 B
qca6490/m3.bin       (2.0 branch)         266,684 B
qca6490/bdwlan.elf   (2.0-branch BDF)      59,900 B
qca6490/regdb.bin                          24,278 B
```

**Independent corroboration of the pattern**, from a different chip and a different project:
`ubuntu-galaxy-tab-s9ultra/docs/development-notes.md:808-810` —
*"Do not use the Samsung HMT.2.0 BDF with the official HMT.1.1 amss: it crashes with MHI
RDDM. The QRD BDF with its ELF wrapper is the definitive one, and must not be stripped."*
That is WCN7850/ath12k/`WLAN.HMT`, this is WCN6855/ath11k/`WLAN.HSP` — same 1.1-vs-2.0
shape, same RDDM outcome, reached independently. The pattern is real.

Corroborating micro-evidence that 2.0 added RF features 1.1 lacks: a strings diff of the two
images shows `phyrf_tpc_GetTxPowerOffset` and `qxm_edpd_TenureProbe` present **only** in
HSP 2.0 (new transmit-power-control and enhanced-DPD code paths). See §6.

---

## 3. NEW: round 3's "version-matched pair" was not version-matched

`docs/porting-log.md:3596-3694` describes attempt #1 as pairing `amss20.bin` with Samsung's
BDF and calls it *"a real, version-matched pair"*. The recorded procedure backs up and
restores **`amss.bin` and `board-2.bin` only** — `m3.bin` is never mentioned.

```
sha256  f91047ad41dcb92789fbf56b865a14b75ee68be4336a1b7d4f93205bc6bbbcce  vendor qca6490/m3.bin
sha256  0c590881870d0e6e98fc7d393ce05690e09287933b1b535e935bf5d98b77713f  community WCN6855/hw2.1/m3.bin
cmp -l  →  184,137 differing bytes of a 262,144-byte payload (70 %)
```

Both are single-`PT_LOAD` ELF32 images, `0x4ff00000`, `0x40000` bytes — same slot, entirely
different code. `m3.bin` is real firmware for a co-processor inside the WLAN chip; ath11k
DMAs it and hands the address over QMI (`ath11k_qmi_m3_load`, qmi.c ~2390-2470;
`m3_fw_support = true` for `wcn6855 hw2.1`, `core.c`). `cnss2` loads it from the same
`qca6490/m3.bin` path (`DEFAULT_PHY_M3_FILE_NAME "m3.bin"`, `pci.c:48`).

So attempt #1 actually ran **AMSS 2.0 + M3 1.1 + BDF 2.0**. Running a 70 %-different M3 image
under a different-branch AMSS is an excellent explanation for the observed outcome — a *full
AP hang* with USB gadget networking also dead, which the porting log itself flags as "more
severe than an isolated MHI RDDM would explain" (a wedged WLAN chip that stops responding on
PCIe will hang the AP on the next config/BAR access, whereas a clean RDDM does not).

**This does not prove the matched triple would work. It proves the matched triple has never
been tried.**

Two more supporting facts for that experiment:

* `regdb.bin` is **byte-identical** between the vendor dump and the community set
  (`af5640b31337c36bad1cc2cd48e39132c631abc2c971aea29686caf8b21fcc2f`). The two branches
  still share at least this data format, and there is nothing to swap there.
* `amss20.bin` and `amss.bin` have the same ELF shape (ELF32/ARM, 17 program headers, same
  two leading `PT_NULL` hash/metadata segments, same `0xf0000000` and `0x01400140`
  placements). Nothing about `amss20.bin` looks unloadable by ath11k/MHI.

---

## 4. NEW: the BDF checksum, fully derived and verified (127/127)

Independently re-derived from paired vendor variants (`/tmp/bdf/cktest.py`) and then
verified exhaustively (`/tmp/bdf/ck2.py`):

> For the 58,180-byte board-data payload (the ELF's single `PT_LOAD`):
> **XOR of all even-offset bytes = 0xFF, and XOR of all odd-offset bytes = 0xFF.**
> Equivalently: the 16-bit little-endian word-wise XOR of the whole payload is `0xFFFF`;
> the u16 at offset `0x0a` is the field that makes it so.

Derivation evidence — `bdwlan.elf` vs `bdwlan.elf1`, checksum moves `0x5f58 → 0x585c`
(Δ `0x0704`):
* even-offset byte deltas: `0x020`(⊕04) and six ⊕02 at `0x424,0x426,0x4b0,0x4b2,0x4b4,0x4b6`
  (which cancel) → net ⊕`04` = the low-byte delta ✔
* odd-offset byte deltas: `0x1d1`(⊕07), `0x77f`(⊕01), `0x8b1`(⊕01) → net ⊕`07` = the
  high-byte delta ✔

Verification: over **all 119 community payloads + all 8 Samsung payloads**, the residual
`(evenXOR ^ ck_lo, oddXOR ^ ck_hi)` has exactly **one** distinct value, `(0xFF, 0xFF)`.
Zero exceptions.

Consequences:
* Samsung's pristine `bdwlan.elf` has a **valid** checksum.
* Candidate A (tested as test #6) also has a **valid** checksum — verified directly against
  the rule. So "the firmware rejected a bad checksum" is **excluded** as the cause of that
  crash.
* Any future patched BDF can be made checksum-correct deterministically. All candidates in
  §8 are emitted with a valid checksum.

---

## 5. What is now positively **excluded**

| hypothesis | status | evidence |
|---|---|---|
| `board-2.bin` container / TLV / IE lengths wrong | **excluded** | regdb from the same file downloaded fine (L655-664); name match and `board api 2` selection succeeded (L675-677) |
| QMI transport, chunking, `bdf_type`, `file_id`, `total_size`, `end` | **excluded** | all 10 chunks sent, 9 acked; and `cnss2/qmi.c:951-1010` is semantically identical to `ath11k/qmi.c:2323-2400` — same 6144-byte chunk, same `total_size = remaining`, same `file_id = board_id`, same `end` flag, same `bdf_type` enum. Neither driver transforms the payload. |
| Payload **size** / table-geometry mismatch between generations | **excluded** | every one of the 127 payloads (119 community + 8 Samsung) is exactly `0xe344` = 58,180 bytes, all at `PT_LOAD` file offset `0x400`, vaddr `0x1000` |
| BDF **format generation** changed (different field layout) | **excluded, strongly** | the non-zero region boundaries are identical between Samsung's and the community's payloads: `0x160, 0x408, 0x450, 0x4a0, 0x4e0, 0x530, 0x714, 0x84e, 0xb80, 0xdf0, 0x1070, 0x118c…0x1554, 0x15a0…0x179e, 0x17d0, 0x1b74, 0x1ca4, 0x2a84, 0x3204, 0x3247`. Internal self-describing structure agrees too: the channel-group frequency list at `0x3204` is a u16 LE list terminated by `0xff` (Samsung: 5180,5320,5580,5825,6015,6335,6475,6745,7005 — 9 entries; community `HW_GK3`: 9 entries; community default: 11), and the table starting at `0x3268` has exactly that many entries per 16-byte row in **both**. Same schema, same strides, same terminators. |
| Wrong BDF variant (`bdwlan.elf1/2/10`, `bdwlang.*`) | **excluded** | `board_id 0xff` + `chip_id & 0x10 == 0` ⇒ `ELF_BDF_FILE_NAME "bdwlan.elf"` (`cnss2/qmi.c:702-711`). The numbered suffixes are `ant_from_macloader` values (`cnss2/qmi.c:644-676`: 1 = chain-1-only, 2 = chain-2-only, 10 = GTX-disabled), a sysfs-driven factory/rework path, not a normal unit. `qcom,bdf-postfix-name` appears in **no** DTS in the Samsung tree, so no postfix. |
| Bad checksum | **excluded** | §4 |
| ELF **wrapper** geometry | *not yet excluded* — see candidate A3 in §8. Attempt 3 stripped the wrapper entirely, which switches ath11k to `bdf_type 0` (`ATH11K_QMI_BDF_TYPE_BIN`, qmi.c:2419-2422) — a different firmware code path — so it did **not** test "Samsung payload, community wrapper". |

---

## 6. What is genuinely different, and where the fatal field must be

Samsung's payload differs from the exact-match community payload (entry [6],
`…subsystem-device=0108,qmi-chip-id=2,qmi-board-id=255`) in **20,991 of 58,180 bytes**.
Most of that is ordinary calibration numbers. Two much sharper measurements:

**(a) Only 62 offsets in the whole control region `0x000–0x1100` put Samsung outside the
[min,max] range of all 119 community payloads** (`/tmp/bdf/anomaly.py`). They cluster into:

* 4 header bit-fields: `0x19=07`, `0x1a=20` (community: always `00`), `0x25=c9`
  (community `01`/`c1`), `0x26=a0` (community `00`/`40`). *These four were already
  normalised in candidate A and it still crashed*, so either they are not the cause or
  they are not the only cause.
* Small scalars: `0x199=42` (comm 00/02), `0x1ca=0f` (comm 08/0d), `0x1d0=2d` (comm 05–20),
  `0x20c=2f`/`0x20e=27` (comm always 1b/13), `0x216=05` (comm always 06), `0x08a8=1c`,
  `0x09d9=5a`/`0x09da=52` (comm always 1d/15).
* **Four blocks of coefficients that are non-zero in Samsung and zero in every single one
  of the 119 community board files**:
  * `0x059c–0x05a3`: `d5 5d c2 5e d4 5f 00 60` (a monotonically ascending u16 sequence
    `0x5dd5, 0x5ec2, 0x5fd4, 0x6000`)
  * `0x0755–0x075c`: `10 7e 98 2f 08 7d 98 2f`
  * `0x0887–0x088e`: `10 be e8 3f 10 be e8 3f` (the same 32-bit value twice)
  * `0x09b9–0x09c0`: `10 be e8 3f 10 be e8 3f` (same again)
  * plus `0x0248–0x024f` (`f1 14 11 01 01 00 f1 10`) and two eight-byte `08 08 08 08 08 08
    08 08` arrays at `0x0254` and `0x0268`, again all-zero in every community file.

  Read as IEEE-754 LE floats these are `0x3fe8be10 ≈ 1.8183` and `0x2f987e10 ≈ 2.8e-10` —
  the shape of slope/intercept pairs. The firmware contains matching symbol names
  `GenOnepointCalData4BrdData`, `GetPreCalData`, `ResetonepointCALData`,
  `GenRxGainCalData4BrdData`. This is per-board power-detector / one-point calibration that
  Samsung populates and no laptop OEM in linux-firmware does.

**(b) Beyond `0x1100` the difference is bulk numeric**: 5,992 of 53,828 offsets out of the
community range, in obviously tabular form (e.g. `0x15a0` onward, stride `0x14`: community
`8c 5a 3c 28 19` = 140/90/60/40/25, Samsung `76 51 31 20 15` = 118/81/49/32/21 — a power or
gain-backoff ladder). Samsung additionally fills whole tables the community leaves at zero
with uniform values (`0x081a4–0x082c4` all `0x14`, `0x0deaa–0x0e08a` all `0x28`,
`0x090d4–0x093a4` a repeating 32-byte pattern). Data, not control.

**The most plausible mechanism**, consistent with all of the above and with the HSP 2.0-only
`phyrf_tpc_GetTxPowerOffset` / `qxm_edpd_TenureProbe` symbols: a feature bit or coefficient
block that only the 2.0 firmware defines is set in this BDF; the 1.1 `_LITE` firmware either
lacks the handler or sizes the corresponding table differently, and faults or asserts while
applying it. **This is a mechanism, not a proof — I cannot name the field.**

### 6.1 An avenue that was investigated and did not pan out (recorded so nobody repeats it)

Both `amss.bin` and `amss20.bin` contain a `PT_LOAD` at vaddr **`0x01400140`, size `0x0e340`**
— 4 bytes short of the BDF payload size, and sitting at the very base of the WLAN chip's SRAM
(`ath11k` `core.c`: `sram_dump.start = 0x01400000`). It looked like the BDF landing buffer.
It is **byte-identical between the two firmware generations** (`cmp -l` → 0 differences),
which would have been useful evidence, but:
* it contains no `0x5634127f` BDF magic (neither image contains that constant anywhere);
* its non-zero region layout does not match any real BDF's;
* the address appears in no code literal in either image.
So it could not be identified and no conclusion rests on it. Extracted copies are kept at
`/tmp/bdf/embedded/hsp{11,20}_embedded_bdf.bin` in case a future session can identify it.

---

## 7. What is missing, precisely

To name the fatal field from static analysis alone you would need **one** of:

1. **Qualcomm's `bdwlan` field schema for QCA6490/WCN6855** (the `bdencoder`/`bdf` XML or the
   `wlan_bdf` header set). Not public; the OpenWrt/ath11k community reached the same wall
   (see the OpenWrt thread already cited in `docs/porting-log.md:3453`). This would resolve
   it outright.
2. **The RDDM crash dump from the failing boot — obtainable on this device, right now,
   and never collected.** The path already exists and is already compiled in:
   `ath11k_mhi_op_status_cb` on `MHI_CB_EE_RDDM` (`mhi.c:277-288`) queues `ab->reset_work`
   → `ath11k_core_reset` calls `ath11k_coredump_collect(ab)` (`core.c:2585`) →
   `ath11k_pci_coredump_download` (`pci.c:705`, registered at `pci.c:922`) →
   `mhi_download_rddm_image` (`mhi.c:501-503`, `rddm_size = 0x420000`) →
   `dev_coredumpv()` (`coredump.c:46`). The port's kernel has `CONFIG_DEV_COREDUMP=y` and
   `CONFIG_WANT_DEV_COREDUMP=y`, and `ath11k-$(CONFIG_DEV_COREDUMP) += coredump.o`
   (`Makefile:30`), so `coredump.o` is built in.

   So after any RDDM the dump should appear as `/sys/class/devcoredump/devcd*/data`.
   **Two practical catches:** the devcoredump framework deletes the buffer after ~5 minutes
   if nobody reads it, and reading it once frees it — so it must be copied off promptly and
   automatically, not looked for afterwards. `safe-fw-test.sh` now does that.

   The dump is a 4 MiB RAM image containing the faulting PC and, for an assert, the
   `Asserted in:0x%x:0x%x, line#%d` / `Assertion failed: %s, function %s, file %s, line %d.`
   payload that the community `amss.bin` string table already shows exists. Cross-referenced
   against `amss.bin`'s program headers (`LOAD 0x01421000 …`) with the `elfmap.py` helper
   here, that converts "somewhere among 62 fields" into "this exact function, this exact
   line". **This is the single highest-value cheap next step**, and unlike the A/B tests it
   costs no extra crashes — the next test that crashes will produce it for free.
3. **A second, independent HSP-2.0-generation WCN6855 BDF** from a different vendor, to
   separate "2.0-era BDF" from "Samsung-specific content". None is available; linux-firmware
   ships no HSP 2.0 `amss.bin` or 2.0-era board data for this chip.

Without one of those, byte-patching is guesswork — which is why §8 proposes bisection
rather than more patches.

---

## 8. Candidate files (built, in `/tmp/bdf/candidates/`)

All four are produced by `/tmp/bdf/build_candidates_v2.py` and `/tmp/bdf/build_candidate_d.py`.

**Key methodological change from every previous attempt.** Attempts 1–3 and candidate A all
changed *three* things at once: a newly prepended `ATH11K_BD_IE_BOARD` entry, Samsung's own
ELF wrapper, and Samsung's payload. An RDDM therefore could not be attributed to any of
them. A3/B/C instead **modify entry [6] of the shipped `board-2.bin` in place** — entry [6]
is `bus=pci,vendor=17cb,device=1103,subsystem-vendor=17cb,subsystem-device=0108,qmi-chip-id=2,qmi-board-id=255`,
i.e. the exact name ath11k builds for this device (log L325) and the entry used on every
known-good boot. Container, entry list, entry lengths, ELF header, program header, section
and symbol tables all stay byte-identical to the known-good file; **only the 58,180-byte
payload changes.** File size stays 7,237,392 bytes.

| candidate | payload | Δ bytes vs known-good payload | what a result means |
|---|---|---|---|
| **A3** `board-2.bin.candA3-sspayload-commwrapper`<br>`sha256 bd42249909d7b330eb2c23a11c67b116cab199336fad045d8ca39cd9a606d339` | Samsung's payload, verbatim, inside the **community** ELF wrapper | 20,991 | **Run this first.** Boots ⇒ the crash in attempts 2/6 was Samsung's *ELF wrapper*, not the data — a complete and trivially-fixable win. Crashes ⇒ the payload is confirmed at fault and the wrapper is eliminated as a variable for B and C. |
| **C** `board-2.bin.candC-sscfg-commtables`<br>`sha256 ca58e5d6861f40a910c5be56ca0a1cc7453f001ec067eac23e325bbecc3d77d7` | Samsung `[0,0x1100)` + community `[0x1100,end)` | **138** | The surgical probe. Crashes ⇒ the fatal field is one of **138 bytes in a 4 KiB window**, bisectable to a single field in ~3 more boots. Boots ⇒ the entire config region is safe and the problem is in the bulk tables. |
| **B** `board-2.bin.candB-commcfg-sstables`<br>`sha256 67fa83c5ccc2a16b3edbe584143409b3c2506661bbb2918c64b835cfba0ef44e` | community `[0,0x1100)` + Samsung `[0x1100,end)` | 20,855 | The exact complement of C. **This is also the most likely *useful* artifact**: if it boots, the device is running Samsung's real gain/power/per-channel tables with the community's control fields — which is the substantive half of what this whole effort wanted. |
| **D** `board-2.bin.candD-ssfile-stockfidelity`<br>`sha256 9e08bbe03bc1ea7256b348bdea2357e642711a808abd2230f7e8ca7a5b9daa3e` | entry [6]'s DATA replaced with Samsung's `bdwlan.elf` **file** (its own wrapper), container re-emitted with correct lengths (7,237,244 B, −148) | n/a | For **Track 2** only — pair with `amss20.bin` **and** Samsung's `m3.bin`. |

Split point rationale: `0x1100` lies inside `0x10e7–0x118c`, a **165-byte run that is all-zero
in both source payloads**, so it cannot bisect a record. Verified by the builder itself
(it asserts on this). All 62 config-region anomalies of §6(a) and all four Samsung-exclusive
coefficient blocks are below the split; the bulk tables are above it.

Every candidate is emitted with a checksum satisfying §4 (the builder asserts this too).

### Recommended order

1. **A3** — isolates wrapper vs payload. (expected: crash)
2. **C** — 138-byte probe. (this is the informative one)
3. **B** — complement; also the candidate most likely to be *useful* if it boots.
4. If C crashes: bisect its 138 bytes — the builder's `emit()` takes an arbitrary payload,
   so a 4-region split of `[0,0x1100)` is a two-line change.
5. **Track 2 — the version-matched vendor triple, never yet tested:**
   `board-2.bin` = **D**, `amss.bin` = `vendor-firmware-dump/firmware/qca6490/amss20.bin`,
   `m3.bin` = `vendor-firmware-dump/firmware/qca6490/m3.bin`. This is the complete,
   self-consistent `WLAN.HSP.2.0.c11-00358` set the tablet actually runs under Android.
   Higher risk than 1–4 (it replaces the firmware, not just data), but §9 makes even a hard
   hang non-persistent. Residual risks that cannot be excluded statically: ath11k's WMI/CE
   configuration and MHI channel table are written against the 1.1 branch, so a boot failure
   later than BDF download (at `wlan cfg` / `wlan mode` / WMI service-ready) would not be
   surprising even if the BDF itself is finally happy.

---

## 9. `/tmp/bdf/safe-fw-test.sh` — a crash-loop-proof harness

Round 3 needed a TWRP rescue because the test files were copied into
`/lib/firmware/…`, so they were still there on the next boot and ath11k re-probed them
forever. That is avoidable.

The kernel's firmware loader searches a runtime-writable custom path **first**:
`drivers/base/firmware_loader/main.c:471-486` (`fw_path[0] = fw_path_para`,
`module_param_string(path, fw_path_para, …, 0644)`), and skips it when empty (main.c:519-520).
The port has `CONFIG_FW_LOADER=y` (`out/kernel/.config`).

The harness stages candidates in **`/run/fwtest/ath11k/WCN6855/hw2.1/`** (tmpfs) and points
`/sys/module/firmware_class/parameters/path` at `/run/fwtest`. Anything not staged falls
through to `/lib/firmware` automatically, so a board-only test needs only `board-2.bin`.

**Both the parameter and the tmpfs staging directory vanish on reboot.** Any reboot —
including a watchdog reset after a hard hang — comes back on the untouched
`/lib/firmware` set. `/lib/firmware` is never written. A crash loop is structurally
impossible.

It also re-arms `debug_mask=0x1074` and prints what to look for. `--reset` returns to
`/lib/firmware` and reprobes, and repeats round 3's own hard-won warning that after a
firmware crash the chip can need **two** unbind/bind cycles before board data loads again —
a single failed reprobe is not evidence of damage.

---

## 10. Side observation, not part of the BDF question but probably important

From the pre-test steady state in the same log, on a 2.4 GHz link (L43-47):

```
mac sta statistics ppdu rssi[0] -83
mac sta statistics ppdu rssi[1] -49
mac sta statistics ppdu rssi[2] 0
mac sta statistics ppdu rssi[3] 0
mac sta statistics db2dbm 1 rssi comb 207 rssi beacon 0     (207 as s8 = -49)
```

**Chain 1 is receiving at −49 dBm — a strong, healthy signal. Chain 0 is 34 dB below it.**
The antenna hardware and the RF front end are demonstrably fine on at least one chain; the
"−84 to −90 dBm, 6–9 Mbit/s" symptom is what a 2×2 link looks like when one chain is
effectively dead. That is a *much* more specific symptom than "poor throughput", and it is
consistent with the BDF hypothesis (wrong FEM/antenna-switch or LNA-gain configuration for
chain 0 on a board the community BDF was never written for) but is *also* consistent with a
missing antenna-switch/coex GPIO, which would be far cheaper to chase and carries no crash
risk. On an X716B the WLAN antennas are shared with a 5G modem that mainline does not drive.

Worth checking before or alongside any further firmware experiments:
* whether chain 0 is dead on 5 GHz too, or only 2.4 GHz;
* whether forcing `nss=1` / a 1×1 chainmask restores sane throughput (which would confirm
  chain 0 is dragging the link down rather than the link being weak);
* Samsung's DTBO / `cnss2` platform bindings for any WLAN antenna-select or coex GPIO the
  mainline DTS does not drive.

---

## 11. Files produced by this session

```
/tmp/bdf/final-analysis.md              this document
/tmp/bdf/build_candidates_v2.py         builds candidates A3, B, C (in-place entry [6])
/tmp/bdf/build_candidate_d.py           builds candidate D (stock-fidelity, for Track 2)
/tmp/bdf/safe-fw-test.sh                crash-loop-proof on-device A/B harness
/tmp/bdf/candidates/board-2.bin.candA3-sspayload-commwrapper
/tmp/bdf/candidates/board-2.bin.candB-commcfg-sstables
/tmp/bdf/candidates/board-2.bin.candC-sscfg-commtables
/tmp/bdf/candidates/board-2.bin.candD-ssfile-stockfidelity
/tmp/bdf/cktest.py                      checksum derivation from paired vendor variants
/tmp/bdf/ck2.py                         checksum verification across all 127 blobs
/tmp/bdf/anomaly.py                     config-region out-of-range analysis
/tmp/bdf/exclusive.py                   Samsung-exclusive / community-exclusive regions
/tmp/bdf/nz.py, side.py, hdrfields.py   structural comparison helpers
/tmp/bdf/elfmap.py, xref.py, findmagic.py   firmware ELF offset/vaddr and literal xref tools
/tmp/bdf/embedded/hsp11_embedded_bdf.bin, hsp20_embedded_bdf.bin
                                        the unidentified byte-identical 0xe340 SRAM region (§6.1)
/tmp/bdf/s11.txt, s20.txt               sorted string sets of the two firmware images
```

Nothing outside `/tmp/bdf/` was modified.

---

## Part 2 — the WMM-params firmware NULL-deref (matched-firmware crash)

# Test 9 (Samsung BDF + matched HSP.2.0 firmware) — root cause of the late `MHI_CB_EE_RDDM`

Author: analysis session 2026-09-09
Inputs:
* `/tmp/bdf/live-test9-candD-verbose-dmesg.log` (1578 lines, `debug_mask=0x1074`)
* `/tmp/bdf/coredumps/rddm-20260909-144314-devcd1.bin` (16,646,684 B, first-crash RDDM)
* `vendor-firmware-dump/firmware/qca6490/amss20.bin` (Samsung `WLAN.HSP.2.0.c11-00358`)
* `buildroot/firmware-overlay/lib/firmware/ath11k/WCN6855/hw2.1/amss.bin` (community `WLAN.HSP.1.1-03125`)
* `kernel/linux/drivers/net/wireless/ath/ath11k/{mac.c,wmi.c,wmi.h}`
* `android_kernel_samsung_gts9/Kernel/vendor/qcom/opensource/wlan/{fw-api,qca-wifi-host-cmn,qcacld-3.0}`

---

## 0. Bottom line

The crash is **fully identified, byte-exact, and deterministic**:

> Mainline ath11k sends `WMI_VDEV_SET_WMM_PARAMS_CMDID` (0x500D / 20493) to vdev 0 immediately
> after vdev creation, while the vdev is created-but-not-started (no channel context, no BSS,
> no peer). The `WLAN.HSP.2.0` firmware's handler for that command executes
> `r3 = memub(r3 + ##0x608)` at PC `0x017be7d0` where `r3` was loaded from a firmware-internal
> pointer `wal_pdev->[0x37c]` that is **NULL** at that point in bring-up. The resulting load
> from address `0x00000608` is an unmapped-address exception on the Q6/Hexagon core, which
> QuRT escalates to a fatal error → `MHI_CB_EE_RDDM`.
>
> The `->[0x37c]->[0x608]` code sequence **does not exist anywhere in the older community
> `HSP.1.1` firmware** — it is new code in `HSP.2.0`, and it has **no NULL guard**.

This is a genuine **firmware-generation incompatibility**, and specifically a *firmware bug*
(missing NULL check in new HSP.2.0 code) exposed by a host behaviour that the downstream
Qualcomm host driver (qcacld-3.0) never exhibits: qcacld only ever sends EDCA/WMM params for a
vdev that already has a PE session and a self-peer, whereas mac80211 sends them unconditionally
at `ifup` time.

There is a **concrete, small, testable host-side workaround** (defer `conf_tx` until
`arvif->is_started`), plus two **zero-code-change confirmation experiments** — see §7.

Framing correction to the task brief: there was **no** ~950 ms of "active operation", and **no
scan or association** ever happened. The firmware stopped servicing WMI **878 ms before** the
`MHI_CB_EE_RDDM` notification; that 878 ms is the firmware's own crash-handling → RDDM-entry
latency (886 ms in the second cycle — see §2.3). The last thing the chip ever did was parse one
WMM command during interface bring-up.

---

## 1. What actually happened, host side

### 1.1 The BDF is genuinely fine (confirmed, not re-litigated)

* `log:67` — `fw_build_id WLAN.HSP.2.0.c11-00358-QCAHSPSWPL_V1_V2_SILICONZ-1.44583.17.50066.50`
* `log:409` / `log:492` — both `qmi BDF download sequence completed` (regdb `bdf_type 4`, then
  board data `bdf_type 1`, 10 chunks, `remaining 0`).
* `log:468` — `boot found match board data for name 'bus=pci,vendor=17cb,device=1103,...,qmi-board-id=255'`
* The chip then reached `MHI_CB_EE_MISSION_MODE`, HTC/WMI came up (`log` around
  `[3756.967301] htc service WMI connect response status 0x0 assigned ep 0x2`), mac80211
  registered `wlp1s0` (`log:592`), and a vdev was created (`log:672`).

So the BDF work from tests 1–8 is done. Nothing below is about the BDF.

### 1.2 The exact last WMI command the firmware ever received

`debug_mask=0x1074` = `HTC|MAC|BOOT|QMI|PCI`. Note **`ATH11K_DBG_WMI` (0x2) was NOT set**
(`kernel/linux/drivers/net/wireless/ath/ath11k/debug.h:15`), so there are no per-command WMI
debug lines. The command identity is therefore reconstructed from HTC credit accounting plus
`ath11k`'s own timeout messages — and then **independently confirmed from firmware RAM** (§3.5).

HTC target grants only 2 transmit credits (`[3756.966854] htc target ready
total_transmit_credits 2 target_credit_size 2176`), so WMI is effectively single-outstanding:
every command shows `credits got 1` → `credits consumed 1` → `htc tx skb ... eid 2`, and the
*next* command immediately logs `insufficient credits` until the firmware returns the credit.

Cycle 1 tail (`log:730-745`):

```
[3757.341735] htc ep 2 credits consumed 1 total 0
[3757.341743] htc tx skb 00000000827cde12 eid 2 ...      <- WMI_VDEV_SET_PARAM (PREAMBLE)
[3757.341750] mac Set preamble: 1 for VDEV: 0
[3757.341770] htc ep 2 insufficient credits ...          <- next cmd blocks
[3757.342231] htc ep 2 credits got 1 total 1             <- fw returned credit for PREAMBLE
[3757.342243] htc ep 2 credits consumed 1 total 0
[3757.342248] htc tx skb 000000008294c700 eid 2 ...      <- *** LAST COMMAND EVER SENT ***
[3757.342256] htc ep 2 insufficient credits ...          <- next cmd blocks FOREVER
[3757.342260] htc ep 2 insufficient credits ...
[3758.220493] boot notify status reason MHI_CB_EE_RDDM   <- +878.2 ms
```

The command that blocked forever at `3757.342256` is identified by its own timeout
(`WMI_SEND_TIMEOUT_HZ` = 3 s):

* `log:754-755` — `[3760.565351] wmi command 36866 timeout` /
  `failed to send WMI_STA_POWERSAVE_PARAM_CMDID` (36866 = 0x9002).
  3760.565 − 3757.342 = 3.223 s ✔ (3 s wait + kworker latency).

`ath11k_mac_op_conf_tx()` (`mac.c:5474-5525`) sends, in order:

1. `ath11k_wmi_send_wmm_update_cmd_tlv(..., WMI_WMM_PARAM_TYPE_LEGACY)` → `WMI_VDEV_SET_WMM_PARAMS_CMDID` (20493)
2. optional `mu_edca` (also 20493) — **did not fire**, otherwise the timeout would read 20493, not 36866
3. `ath11k_conf_tx_uapsd()` → `ath11k_wmi_set_sta_ps_param()` → `WMI_STA_POWERSAVE_PARAM_CMDID` (36866) — `mac.c:5414-5420`

Therefore **the command at `3757.342248` was `WMI_VDEV_SET_WMM_PARAMS_CMDID`**, and the firmware
never returned its HTC credit — i.e. it died while processing it.

The remaining three `conf_tx` calls (mac80211 calls it once per AC) then time out on their own
WMM send: `log:761-762`, `769-770`, `775-776` — three × `wmi command 20493 timeout /
failed to send WMI_VDEV_SET_WMM_PARAMS_CMDID`. Four `conf_tx` calls total ✔.

### 1.3 Why ath11k sends this so early

`net/mac80211/iface.c:1578` — `ieee80211_do_open()` calls
`ieee80211_set_wmm_default(&sdata->deflink, true, sdata->vif.type != NL80211_IFTYPE_STATION)`.
`net/mac80211/util.c:1025-1130` — this loops all four ACs and calls `drv_conf_tx()` for each,
with `chanctx_conf == NULL` (there is no channel yet), so for a STA it uses the plain 802.11-2007
defaults `cw_min=15, cw_max=1023, aifs=2, txop=0, uapsd=false` for **all four** ACs.

Corroborating log evidence that the vdev was *not* started:
`log:722` — `mac defer protection mode setup, vdev is not ready yet`, which is the
`else` branch of `if (arvif->is_started)` in `mac.c:3639-3657`.

So: interface-up → vdev create → `bss_info_changed` (slottime, preamble) → **`conf_tx` × 4**.
No scan, no `vdev_start`, no `vdev_up`, no peer.

### 1.4 What downstream does instead

`qca-wifi-host-cmn/wmi/src/wmi_unified_tlv.c:5291` `send_process_update_edca_param_cmd_tlv()` is
reached only from:

* `qcacld-3.0/core/wma/src/wma_mgmt.c:2074` `wma_process_update_edca_param_req()` — requires
  `wma_is_vdev_valid(vdev_id)`, driven by `WMA_UPDATE_EDCA_PROFILE_IND`;
* `qcacld-3.0/core/mac/src/pe/lim/lim_process_sme_req_messages.c:7294`
  `lim_process_sme_update_edca_params()` — requires a `pe_session` **and** a self entry in the
  DPH hash table (`sta_ds_ptr`), i.e. an established BSS.

**qcacld never sends this command on a bare, unstarted vdev.** That is exactly the untested
firmware path mainline ath11k walks into.

---

## 2. Firmware side: exact fault

### 2.1 The coredump layout (reusable recipe)

`rddm-*.bin` is `struct ath11k_dump_file_data` (`ath11k/coredump.h:36-55`), 196-byte header then
8-byte TLVs. Parsed by `/tmp/bdf/parse_coredump.py`:

```
TLV @0xc4      type=0 PAGING_DATA      len=5767344   -> /tmp/bdf/coredumps/paging.bin (mhi fbc_image, an ELF)
TLV @0x58017c  type=1 RDDM_DATA        len=4718736   -> /tmp/bdf/coredumps/rddm.bin
TLV @0xa00214  type=2 REMOTE_MEM_DATA  len=6160384   -> /tmp/bdf/coredumps/remote.bin (QMI HOST_DDR seg)
```

`rddm.bin` is an MHI RDDM table (`version=1, header_size=392`, 64-byte entries
`{u64 base, u64 actual_phys, u64 size, char desc[20], char file[20]}`), parsed by
`/tmp/bdf/rddm_table.py`:

| # | desc | dev range | payload offset in rddm.bin |
|---|------|-----------|----------------------------|
| 0 | `Q6-SRAM`      | `0x1400000..0x1780000` | `0x188` |
| 1 | `ETB_SOC_32K`  | 16 KiB | `0x380188` |
| 2 | `ETB_WCSS_32K` | 32 KiB | `0x384188` |
| 3 | `PHYA-M3`      | 256 KiB | `0x38c188` |
| 4 | `PHYB-M3`      | 256 KiB | `0x3cc188` |
| **5** | **`Q6-SFR`** (subsystem failure reason) | `0x16cd010..0x16cd060` | **`0x40c188`** |

**`Q6-SFR` is the single most valuable 80 bytes in the whole 16 MB dump.** Its content here:

```
:0:0x8ExIPC: Exception recieved tid=1a inst=17be7d0 cause=7003
```

(the live SRAM copy at dev `0x16cd010` = `rddm.bin+0x2cd198` reads
`:0:ExIPC: Exception recieved tid=1a inst=17be7d0 cause=7003` — the two copies differ by a
leading `0x8`, see §6.2.)

### 2.2 The firmware is Hexagon/QuRT, not ARM

`amss20.bin`'s ELF header says `EM_ARM` with 0 section headers, but that is only Qualcomm's PIL
convention. The RDDM region names (`Q6-SRAM`, `Q6-SFR`) and the string table settle it:

* `rddm.bin` strings include `QURT_fatalNotif`, `Assertion ret == QURT_EOK failed`,
  `Assertion res == QURT_EOK failed`,
  `Assertion ret == QURT_EOK && (swapped_segments_boundaries_ptr->start_addr) <= pf_data.fault_addr && ... failed`,
  `Non Page Fault Exception cause code : 0x %x at Address : 0x %x `,
  `ExIPC: Exception recieved tid=%x inst=%x cause=%x`, `ERR_FATAL_EXCEPTION_REENTRANCY`.

Disassembling `amss20.bin` with `llvm-mc --disassemble --triple=hexagon` produces clean,
self-consistent Hexagon code (helpers `/tmp/bdf/dis2.py`, `/tmp/bdf/dis3.py`, `/tmp/bdf/dis4.py`).
`llvm-objdump` in this environment has the `hexagon` target registered.

Address mapping (`amss20.bin` program headers): the fault PC `0x017be7d0` lies in
`LOAD off=0x193000 vaddr=0x01705000 filesz=0x230000 R E`, i.e. file offset **`0x24c7d0`**.
Note this region is *above* the `Q6-SRAM` window (`…0x1780000`) — it is demand-paged from the
MHI `fbc_image` in host DDR, which is why the firmware has a page-fault/segment-swap subsystem
at all.

### 2.3 The faulting packet

`0x017be7d0` is a genuine Hexagon packet boundary (verified by parse-bit walks from five
independent start addresses, `/tmp/bdf/pkts.py`). The packet is 2 words = 8 bytes at file offset
`0x24c7d0`: `18 40 00 00 03 c1 23 91` = `immext(0x600)` + `memub`:

```
017be7d0 (2 words):   r3 = memub(r3 + ##0x608)      <<<< fault PC from Q6-SFR
```

It is the **only** memory access in the packet — so the exception is a data-side fault on that
byte load. Immediately preceding it (exact addresses, `/tmp/bdf/dis2.py 17be64c 17be844`):

```
017be7b4 (3w):  r1 = and(r17,#0xff)
                r3 = memw(r16+#0x28)         ; r16 = vdev object
                r4 = memub(r16+#0x234)       ; mac/pdev index
017be7c0 (1w):  r3 = addasl(r3,r4,#0x2)
017be7c4 (1w):  r3 = memw(r3+#0x1f4)         ; soc->pdev_ptr[mac_id]
017be7c8 (1w):  r0 = memw(r3+#0x20)          ; pdev->wal_pdev
017be7cc (1w):  r3 = memw(r0+#0x37c)         ; wal_pdev->[0x37c]      <-- returns NULL
017be7d0 (2w):  r3 = memub(r3+##0x608)       ; *** load from 0x00000608 -> exception ***
017be7d8 (1w):  p0 = cmp.eq(r2,r3); if (!p0.new) jump:t <loop tail>
```

**Verified against live memory in the dump** (`Q6-SRAM` payload at `rddm.bin+0x188` maps
`0x1400000`):

| step | expression | live value |
|---|---|---|
| global | `*0x01602758` | `0x01692700` (soc) |
| vdev0 | `*(soc + 0x38 + 0*4)` | `0x016b38c8` |
| `vdev->0x2c` (checked non-NULL by the handler) | | `0x016a7498` |
| `vdev->0x28` | | `0x01692700` |
| `vdev->0x234` (mac id) | | `0` |
| `*(soc + 0x1f4)` | pdev[0] | `0x016a0438` |
| `*(pdev0 + 0x20)` | wal_pdev | `0x01655830` |
| **`*(0x01655830 + 0x37c)`** | | **`0x00000000`** |
| `memub(0x0 + 0x608)` | | **unmapped → exception** |

The same field is NULL for the second radio's object too (`*(pdev1+0x20) = 0x01666000`,
`+0x37c = 0`), so this is not a per-band accident.

### 2.4 The enclosing function *is* the WMM handler — proven by struct layout

Function `0x017be64c .. 0x017be82f` (prologue `call <stack chk>; allocframe(#0x78)`; epilogue
`jump <dealloc helper>` at `0x017be82c`). Its prologue:

```
017be64c:  allocframe(#0x78)
017be654:  r18 = memw(r0+#0x0)            ; r18 = WMI command payload pointer
           r0  = memw(##0x1602758)        ; soc
017be660:  call 0x0156f4d8                ; vdev lookup
           r1  = memw(r18+#0x4)           ; ---> cmd->vdev_id  @ +0x04
017be668:  p0 = cmp.eq(r0,#0x0); if (p0) jump <err>
017be66c:  r16 = r0                       ; r16 = vdev
           r2  = memw(r0+#0x2c)
017be674:  p0 = cmp.eq(r2,#0x0); if (p0) jump <err>
           if (!p0.new) r25 = memw(r18+#0x78)   ; ---> cmd->wmm_param_type @ +0x78
017be67c:  r21 = add(r18,#0x20)                 ; ---> &cmd->wmm_params[0].no_ack
           p0 = cmp.gtu(r25,#0x1); if (p0) jump <err>   ; wmm_param_type must be 0 or 1
```

and the AC loop body reads exactly six words per entry and advances by 28:

```
017be6b0:  r26 = memw(r21+#-0x14)   ; cwmin
017be6c4:  r27 = memw(r21+#-0x10)   ; cwmax
017be6cc:  r19 = memw(r21+#-0x0c)   ; aifs
017be6d4:  r23 = memw(r21+#-0x08)   ; txoplimit
017be6dc:  r2  = memw(r21+#0x00)    ; no_ack
017be6fc:  r2  = memw(r21+#-0x04)   ; acm
   ...
017be800:  r22 = add(r22,##0x10000) ; ac<<16 for the log
           r21 = add(r21,#0x1c)     ; += sizeof(wmi_wmm_params) == 28
017be808:  jump 0x017be6b0          ; loop head
```

Overlay this on the authoritative struct
(`fw-api/fw/wmi_unified.h:24096-24115` and `ath11k/wmi.h:5365-5370`):

```c
typedef struct {                 /* wmi_vdev_set_wmm_params_cmd_fixed_param */
    A_UINT32 tlv_header;         /* +0x00 */
    A_UINT32 vdev_id;            /* +0x04  <- r18+0x04    */
    wmi_wmm_vparams wmm_params[4];/* +0x08, 4 x 28 bytes  */
    A_UINT32 wmm_param_type;     /* +0x78  <- r18+0x78    */
} ;                              /* total 0x7C = 124      */
```

`r21 = r18 + 0x20` is `&wmm_params[0].no_ack` (0x08 + 0x18). Every offset matches. The
`cmp.gtu(r25,#1)` bound check matches `WMM_PARAM_TYPE_LEGACY=0 / WMM_PARAM_TYPE_11AX_EDCA=1`
(`fw-api/fw/wmi_unified.h:10092-10094`).

The rest of the loop body is the classic WMM AC remap
(`ac 0→2, 1→3, 2→1, 3→0`, i.e. host BE/BK/VI/VO → firmware priority order VO/VI/BE/BK), built
from `and(r17,#0x7ffffffe)` / `mux(p0,#0x3,#0x2)` at `0x017be784..0x017be7b0`. The fault happens
on **loop iteration 0** because the `->0x37c->0x608` chain is loop-invariant.

### 2.5 Independent confirmation: the command itself, recovered from firmware RAM

Searching the dump for the predicted payload (`cwmin=15, cwmax=1023, aifs=2`) found exactly one
hit, in `Q6-SRAM` at device address **`0x014823c8`**:

```
dev 0x014823c8:  0000500d 00c70078 00000000 00c70018   <- WMI cmd id 20493, then TLV hdr, vdev_id=0
dev 0x014823d8:  00000000 ...                            wmm_params[0] BE : all zero
dev 0x014823ec:  00c70018 00000000 ...                   wmm_params[1] BK : all zero
dev 0x01482408:  00c70018 00000000 ...                   wmm_params[2] VI : all zero
dev 0x01482428:  00c70018 0000000f 000003ff 00000002     wmm_params[3] VO : cwmin=15 cwmax=1023 aifs=2
dev 0x01482438:  00000000 00000000 00000000              txop=0 acm=0 no_ack=0
dev 0x01482444:  00000000                                wmm_param_type = 0 (LEGACY)
```

* WMI command id word = **`0x0000500D` = 20493 = `WMI_VDEV_SET_WMM_PARAMS_CMDID`** ✔
* outer `tlv_header = 0x00C70078` → tag **199 (0xC7)**, len **120** = `sizeof(cmd)-4` ✔
  (the firmware's TLV validator accepted it, so ath11k's tag matches this firmware's expectation)
* inner `tlv_header = 0x00C70018` → same tag, len 24 = `sizeof(wmi_wmm_params)-4` ✔
* Three ACs are all-zero because `ath11k_mac_op_conf_tx()` fills only the one AC mac80211 asked
  for and then transmits the whole `arvif->wmm_params` (`mac.c:5474-5512`). This is a real
  host-side wart (see §6.1) but **is not** the proximate cause — the fault is AC-independent.

This is the actual killing command, sitting in the chip's RAM at the instant it died.

---

## 3. Why HSP.1.1 survives and HSP.2.0 does not

The exact 8-byte fault packet (`immext(0x600)` + `r3 = memub(r3+##0x608)`,
bytes `18 40 00 00 03 c1 23 91`) occurs:

* in **`amss20.bin` (HSP.2.0)** at file offsets `0x235658`, `0x24c7d0`, `0x38b774`
  = vaddrs **`0x017a7658`, `0x017be7d0`, `0x018fd774`**
* in **community `amss.bin` (HSP.1.1)**: **0 occurrences**

Both searches are **whole-file, exhaustive byte/encoding scans** of the complete images
(5,496,832 B and 4,988,928 B), not partial disassemblies, so "0 occurrences" is a complete
negative, not a sampling artefact.

Broader check — every `immext(0x600)` word in both images was decoded together with its
successor instruction:

* HSP.2.0 has 180 such words, five of which touch a `+0x608` **byte** field through a pointer:
  three identical `r3 = memub(r3+##0x608)` reads (the three sites above, each preceded by the
  same inlined AC-remap and each followed by `cmp.eq(r2,r3)` and a call to `0x017b8ae4`),
  plus two writers `memb(r19+##0x608) = r2` @ `0x017b8b3c` (inside `0x017b8ae4`) and
  `memb(r0+##0x608) = r2` @ `0x01813c9c` (the object's initializer, which sets it to 3).
* HSP.1.1 has 165 such words and **none** of them is a `memub/memb` on a `+0x608` byte field.
  Its only `##0x608` data access is a word store `memw(r3+##0x608) = r4` @ `0x018984b0`,
  unrelated.

**Conclusion: `wal_pdev->[0x37c]->[0x608]` is new machinery introduced in `WLAN.HSP.2.0`.** It is
read from three call sites, none of which NULL-check `+0x37c`. One of those three is the
`WMI_VDEV_SET_WMM_PARAMS` handler, and it is reachable before the object is created.

---

## 4. What `wal_pdev->[0x37c]` is, and what is *not* determinable

What is known:

* It is a pointer field on the WAL/WHAL per-radio object (`*(soc->pdev[i] + 0x20)`;
  `0x01655830` for radio 0, `0x01666000` for radio 1; both share `+0x28`, `+0x2c`, `+0x270`,
  `+0x660` values, so they are the same type).
* Its `+0x608` byte holds an AC index in firmware priority order; it is initialised to `3` at
  allocation and mutated by `0x017b8ae4`. The three read sites all do
  `if (remapped_ac == obj->[0x37c]->[0x608]) call 0x017b8ae4(...)` — i.e. "is this the AC we are
  currently tracking?". Semantically this smells like a per-radio *current/critical AC* tracker
  (EDCA/latency/airtime related), but that is inference, not evidence.
* The only writer that stores a **pointer** into `+0x37c` and initialises the new object's
  `+0x608` is at **`0x01813c74`**, inside a large routine beginning near `0x018110b8`:

  ```
  01813c5c:  r2 = memw(r16+#0x37c)
  01813c60:  p0 = cmp.eq(r2,#0x0); if (!p0.new) jump <skip>   ; only allocate once
  01813c68:  r2 = memw(r16+#0x270)
  01813c6c:  r17 = memw(r2+#0x460)                            ; memory pool handle
  01813c70:  call <alloc>;  r0 = memw(r17+#0x0)
  01813c74:  memw(r16+#0x37c) = r0
  01813c9c:  memb(r0+##0x608) = #3
             memw(r0+#0x0) = r16                              ; back-pointer to owner
  ```

  `*(0x01655830 + 0x270 + 0x460)` = `0x01a18a00` in the live dump — a plausible pool handle — so
  the object type matches, but the routine never reached that point in this boot.

**What is NOT determinable with what is available**: the host-visible precondition that makes the
firmware run that allocation. `amss20.bin` is fully stripped (0 section headers, no symtab), the
log strings use QShrink-2.0 hashes (`r0 = ##0xc801d585`, `r1 = #0x254` — a 32-bit message hash
and a source line number, not a format-string pointer), and no message-hash database is present
in this repo. Naming the routine, or the WMI command / `wmi_resource_config` field / service bit
that reaches it, would require **one** of:

1. the QShrink message DB (`*.msg`/`qshrink` xml) for build
   `WLAN.HSP.2.0.c11-00358-QCAHSPSWPL_V1_V2_SILICONZ-1.44583.17.50066.50`, which would decode the
   embedded line numbers and file identities directly; or
2. a symbolised/unstripped build of this firmware; or
3. substantially deeper static reverse engineering (walk every caller of `0x018110b8` and every
   WMI/CE entry point back to the dispatcher) — feasible in principle with the tooling built here
   (`/tmp/bdf/dis3.py` disassembles the whole 2.2 MB pageable segment with correct addresses in
   `/tmp/bdf/A_1705000.dis`), but it is many hours of work with an uncertain payoff, because the
   answer may well be "the object is created at `VDEV_START`/channel-assign time", which is
   already the operating hypothesis and is *directly testable in one live run* (§7).

**Cause code `0x7003`: not resolvable from anything available locally.** It is not a raw Hexagon
`SSR[CAUSE]` value (those are 8-bit; `0x70` alone would be "TLB miss RW, read", which is
consistent with a load from unmapped `0x608`, but the low byte `0x03` has no local corroboration).
No cause-code table or decoding string exists in either firmware image, in
`android_kernel_samsung_gts9`, or in the mainline tree. Fortunately **it does not matter**: the
faulting instruction, the faulting address (`0x608`), and the reason it is bogus (NULL base) are
all established directly from the disassembly plus live memory, so the cause encoding adds
nothing.

---

## 5. Ruled out

| Hypothesis | Verdict | Evidence |
|---|---|---|
| BDF format/parse problem | **Ruled out** | Both BDF downloads complete; chip reaches mission mode and serves WMI for 375 ms (`log:409,468,492`, `log:592`). |
| ath11k uses the wrong WMI TLV tag for the inner `wmi_wmm_params` (it uses `WMI_TAG_VDEV_SET_WMM_PARAMS_CMD`, spec says `WMITLV_TAG_STRUC_wmi_wmm_params`) | **Ruled out (and downstream does the same)** | `qca-wifi-host-cmn/wmi/src/wmi_unified_tlv.c:5321-5323` sets the inner header to `WMITLV_TAG_STRUC_wmi_vdev_set_wmm_params_cmd_fixed_param` too. `fw-api/fw/wmi_tlv_defs.h:3514-3517` shows the WMITLV table has a single `WMITLV_SIZE_FIX` fixed_param element, so inner tags are never validated; and the disassembly shows the handler never reads offset `+0x08` (the inner tlv_header). |
| Command length / layout mismatch between mainline and HSP.2.0 | **Ruled out** | Recovered on-wire bytes (§2.5) match `fw-api`'s struct exactly; the firmware's own field offsets (`+0x04`, `+0x78`, stride 28) match; the TLV validator accepted len=120. |
| Scan / association / NetworkManager activity | **Ruled out** | No `mac scan`/`ath11k_scan_event` activity in the log; `arvif->is_started == false` at crash (`log:722`); crash is 878 ms *after* the last host→fw traffic, and the mac80211 ops in flight were only `add_interface` → `bss_info_changed` → `conf_tx`. |
| Missing WMI service-bitmap / capability negotiation step | **Not the proximate cause** | The crash is a NULL deref in a handler the host is entitled to call. A missing `wmi_init` resource-config knob *could* be why `+0x37c` is unallocated (§4), but that is unproven and, either way, the deterministic trigger is the early `conf_tx`. |
| Missing HTC credits / host-side deadlock | **Ruled out as cause** | Credits stop because the firmware died, not vice versa; the RDDM notification confirms a firmware exception with a recorded PC. |

---

## 6. Secondary observations (lower priority, but real)

### 6.1 ath11k sends three all-zero AC entries on the first `conf_tx`

`ath11k_mac_op_conf_tx()` (`mac.c:5474-5525`) updates only `arvif->wmm_params.ac_<x>` for the AC
mac80211 passed, then ships the entire 4-AC array. On the first call after `ifup`, three of the
four entries are `{cwmin=0, cwmax=0, aifs=0, txop=0, acm=0, no_ack=0}` — verified on the wire in
§2.5. qcacld always populates all four (`wma_mgmt.c:2098-2126`). This is a latent
"we hand the firmware invalid EDCA parameters four times in a row" bug independent of the crash,
and it is fixed for free by the deferral in §7.

### 6.2 Two slightly different `Q6-SFR` strings

`rddm.bin+0x40c188` (the RDDM `Q6-SFR` region copy) reads
`:0:0x8ExIPC: Exception recieved tid=1a inst=17be7d0 cause=7003` (62 chars) while the live
`Q6-SRAM` copy at dev `0x16cd010` reads `:0:ExIPC: ... cause=7003` (59 chars, cleanly
NUL-terminated). Same PC, same tid, same cause. The `:0:` prefix is an empty-filename/zero-line
QuRT err_fatal prefix; the extra `0x8` in one copy is probably an error-code field present in one
of the two writes. Not load-bearing.

### 6.3 `failed to process regulatory info -22` on the recovery boot

`log:1359` — `[3771.587658] failed to process regulatory info -22`, from
`ath11k_reg_handle_chan_list()` via `ath11k_reg_chan_list_event()` (`wmi.c:7264`). This appears
**only** on the second (recovery) boot, not the first, so it is most likely a recovery-path
artefact rather than an HSP.2.0 TLV incompatibility — but it is worth re-checking on any future
HSP.2.0 run, since a regulatory-event layout change would be a second, independent
firmware-generation issue.

### 6.4 The two crash cycles are identical in mechanism, different in preamble

Cycle 2 (`log:1526-1546`) has **no** `Set slottime` / `Set preamble` / `defer protection mode`
lines — mac80211's reconfig path passes a different `changed` mask — yet it still dies right
after the last WMI send following `mac interface added to change reg rules`, and its first
timeout is again `36866 WMI_STA_POWERSAVE_PARAM_CMDID` (`log:1545-1546`), proving the last
accepted command was again `WMI_VDEV_SET_WMM_PARAMS_CMDID`. Crash latency: 886.0 ms
(`3771.653816` → `3772.539801`) vs 878.2 ms in cycle 1 — a fixed firmware crash-handling
latency, not variable runtime.

Cycle 2's escalation to a full AP reboot is just `already resetting count 2` (`log:1543`):
ath11k's second reset attempt while the first was still unwinding.

---

## 7. Concrete next experiments

Ordered cheapest-first. All are on the crash-safe tmpfs harness (`/tmp/bdf/safe-fw-test.sh`),
which never touches `/lib/firmware`.

### E1 — zero code change: prove the firmware is stable until `ifup` (5 minutes)

Stage the HSP.2.0 set exactly as in test 9, but make sure **nothing brings `wlp1s0` up**:

```
nmcli device set wlp1s0 managed no        # (or: systemctl stop NetworkManager)
sudo modprobe -r ath11k_pci; ... rebind via safe-fw-test.sh ...
# do NOT run `ip link set wlp1s0 up`
sleep 60; dmesg | tail -40
```

Expected if this analysis is right: `MHI_CB_EE_MISSION_MODE`, WMI up, `wlp1s0` registered, and
**no RDDM at all**, indefinitely. That alone converts "HSP.2.0 crashes" into "HSP.2.0 crashes on
interface bring-up", and it is the single most informative 5 minutes available.

### E2 — zero code change: isolate the trigger to `ifup` (2 minutes, run right after E1)

With NetworkManager still out of the way:

```
sudo ip link set wlp1s0 up
```

Expected: RDDM ~880 ms later, with `wmi command 36866 timeout` /
`failed to send WMI_STA_POWERSAVE_PARAM_CMDID` three seconds after that. This excludes
NetworkManager, scanning and association entirely and pins the trigger to `ieee80211_do_open()`.

**Run E1+E2 with `debug_mask=0x1076`** (add `ATH11K_DBG_WMI = 0x2`) so every WMI command and
event id is printed — this removes the last bit of inference from the credit-accounting
reconstruction and will immediately show the `wmm set type 0 ac N ...` lines from
`wmi.c:2735-2740`.

### E3 — the actual candidate fix: defer `conf_tx` until the vdev is started

A ~30-line ath11k patch, mirroring a pattern the driver already uses for CTS protection
(`mac.c:3639-3657`, `"defer protection mode setup, vdev is not ready yet"`):

* In `ath11k_mac_op_conf_tx()` (`mac.c:5474`): still record `params` into `arvif->wmm_params`
  (and `arvif->muedca_params`), but if `!arvif->is_started`, set a
  `arvif->wmm_params_deferred = true` flag and `return 0` **without** calling
  `ath11k_wmi_send_wmm_update_cmd_tlv()` or `ath11k_conf_tx_uapsd()`.
* In `ath11k_mac_op_assign_vif_chanctx()` (`mac.c:~8420-8446`), right after
  `arvif->is_started = true`, if the flag is set, send the accumulated
  `arvif->wmm_params` once (LEGACY) plus the uAPSD params, and clear the flag.
  `ath11k_mac_start_vdev_delay()` (`mac.c:~7958`) needs the same hook.

Two independent benefits: (a) the NULL-deref window is never entered; (b) the firmware stops
receiving three all-zero AC entries (§6.1), because by then mac80211 has filled all four.

Success criterion: the interface comes up, a scan runs, and the firmware survives past
`vdev_start`. **Failure mode to watch for and how to read it**: if a *different* crash follows,
capture the coredump and re-run the §2.1 recipe — `Q6-SFR` gives the new PC in one step, and
`/tmp/bdf/dis2.py <fn_start> <fn_end>` gives the exact packet. That loop is now cheap; the
expensive part (establishing that this firmware is Hexagon, finding `Q6-SFR`, and validating
the packet-boundary walk) is done.

### E4 — if E3 works and you want the WMM params applied at all

Note the deferred command still has to be sent eventually. If `WMI_VDEV_SET_WMM_PARAMS` *also*
crashes after `vdev_start`, then `wal_pdev->[0x37c]` is created by something else entirely (a
`wmi_init` resource-config field or a service bit), and the next lead is to diff ath11k's
`ath11k_wmi_cmd_init()` / `wmi_resource_config` (`wmi.c`, `wmi.h`) against
`qca-wifi-host-cmn`'s `init_deinit_*` / `target_if` resource config for QCA6490 — specifically
any field mainline leaves at 0 that downstream sets. That is a bounded, source-only comparison
and does not need the firmware symbols.

### E5 — not recommended

Patching the firmware binary (inserting a NULL check) is theoretically possible now that the
exact packet is known, but `amss20.bin` is signed (PIL/MHI BHIe verifies hashes), so a modified
image will not load. Do not spend time there.

---

## 8. Reusable tooling produced

All in `/tmp/bdf/`:

| file | purpose |
|---|---|
| `parse_coredump.py` | splits `rddm-*.bin` into `paging.bin` / `rddm.bin` / `remote.bin` TLVs |
| `rddm_table.py` | parses the MHI RDDM segment table; locates `Q6-SFR` (the crash-reason string) |
| `pkts.py` | Hexagon packet-boundary walker (parse bits 15:14), used to validate a PC |
| `dis2.py` | exact, address-annotated Hexagon disassembly of a small range (packet-accurate) |
| `dis3.py` / `dis4.py` | bulk disassembly of a whole segment with addresses (`A_1705000.dis`) |
| `mem.py` | reads live firmware memory out of the `Q6-SRAM` region of a coredump by device VA |
| `elfmap.py` | (pre-existing) file-offset ↔ vaddr mapping for the PIL ELFs |

Key commands:

```
llvm-mc --disassemble --triple=hexagon --print-imm-hex   # hexagon target is available here
python /tmp/bdf/rddm_table.py                            # find Q6-SFR
python /tmp/bdf/dis2.py 17be64c 17be844 "" 17be7d0        # the WMM handler, fault marked
```
