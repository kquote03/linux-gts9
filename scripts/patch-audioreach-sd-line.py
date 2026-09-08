#!/usr/bin/env python3
"""
Patch an AudioReach topology binary's I2S sink module SD_LINE_IDX token
from I2S_SD0 (1) to I2S_SD1 (2). See scripts/stage-audioreach-topology.sh
for the full "why" -- this file is just the byte-level mechanics.

ALSA topology vendor tuples are little-endian {token: u32, value: u32}
pairs. Token 200 = AR_TKN_U32_MODULE_ID, token 256 =
AR_TKN_U32_MODULE_SD_LINE_IDX (kernel/linux/include/uapi/sound/
snd_ar_tokens.h). We find every occurrence of
{token=200, value=MODULE_ID} and, within SEARCH_WINDOW bytes after it,
look for {token=256, value=1} and flip that value to 2.
"""
import struct
import sys

MODULE_ID = 0x0700100A
TOKEN_MODULE_ID = 200
TOKEN_SD_LINE_IDX = 256
OLD_VALUE = 1
NEW_VALUE = 2
SEARCH_WINDOW = 200


def main():
	inpath, outpath = sys.argv[1], sys.argv[2]
	with open(inpath, "rb") as f:
		data = bytearray(f.read())

	module_id_pat = struct.pack("<II", TOKEN_MODULE_ID, MODULE_ID)
	sd_line_pat = struct.pack("<II", TOKEN_SD_LINE_IDX, OLD_VALUE)

	patched = 0
	start = 0
	while True:
		idx = data.find(module_id_pat, start)
		if idx == -1:
			break
		window_end = min(len(data), idx + SEARCH_WINDOW)
		sub_idx = data.find(sd_line_pat, idx, window_end)
		if sub_idx != -1:
			value_offset = sub_idx + 4  # skip past the token itself
			old = struct.unpack_from("<I", data, value_offset)[0]
			assert old == OLD_VALUE, f"unexpected value {old} at {value_offset}"
			struct.pack_into("<I", data, value_offset, NEW_VALUE)
			print(f"patched SD_LINE_IDX at offset {value_offset} "
			      f"(module id match at {idx}): {OLD_VALUE} -> {NEW_VALUE}")
			patched += 1
		start = idx + 1

	if patched == 0:
		print("ERROR: no matching module-id + sd-line-idx pattern found", file=sys.stderr)
		sys.exit(1)

	with open(outpath, "wb") as f:
		f.write(data)
	print(f"wrote {outpath}, {patched} patch(es) applied")


if __name__ == "__main__":
	main()
