/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Board file for the Samsung Galaxy Tab S9 5G (SM-X716B).
 *
 * UNTESTED / UNFLASHED. Deliberately minimal: no framebuffer device is
 * needed for the Phase 1-3 bring-up MVP -- all SoC/PMIC/UFS/pinctrl
 * bring-up is the mainline Linux kernel's job (see
 * kernel/dts/sm8550-samsung-x716b.dts), not uniLoader's.
 *
 * early_init/late_init ARE used here, temporarily, purely as bring-up
 * diagnostic checkpoints: the first two real flash attempts (2026-09-05)
 * both fell back to Download Mode with zero visibility into whether
 * uniLoader's own code ever ran at all after ABL's handoff (ABL's own log
 * ends at "Exit Boot Services" either way, uniLoader has no logging
 * hooked up by default). These hooks write directly into the same
 * physical sec_log_buf region and on-disk format
 * kernel/drivers/samsung-x716-sec-log.c implements, using the exact same
 * struct layout/magic confirmed from Samsung's downstream source -- so
 * checkpoint text shows up in /proc/last_kmsg via TWRP exactly like the
 * mainline kernel's own console output would, letting us see how far
 * execution actually got. Remove once real progress is confirmed and a
 * better signal (the mainline kernel's own boot log) is available instead.
 */
#include <board.h>
#include <stdint.h>

#define SEC_LOG_ADDR 0x880200000UL
#define SEC_LOG_MAGIC 0x4d474f4cUL
#define SEC_LOG_REGION_SIZE 0x200000UL

struct sec_log_buf_head {
	uint32_t boot_cnt;
	uint32_t magic;
	uint32_t idx;
	uint32_t prev_idx;
	volatile char buf[];
};

static void checkpoint(const char *s)
{
	volatile struct sec_log_buf_head *h =
		(volatile struct sec_log_buf_head *)SEC_LOG_ADDR;
	uint32_t buf_size = SEC_LOG_REGION_SIZE - sizeof(struct sec_log_buf_head);
	uint32_t idx, off, i, len;

	if (h->magic != SEC_LOG_MAGIC) {
		h->magic = SEC_LOG_MAGIC;
		h->idx = 0;
		h->prev_idx = 0;
		h->boot_cnt = 0;
	}

	for (len = 0; s[len] != '\0'; len++)
		;

	idx = h->idx;
	for (i = 0; i < len; i++) {
		off = (idx + i) % buf_size;
		h->buf[off] = s[i];
	}
	h->idx = idx + len;
}

int gts9_5g_early_init(void)
{
	checkpoint("[uniLoader/gts9-5g] early_init reached -- self-relocation + entry survived\n");
	return 0;
}

int gts9_5g_late_init(void)
{
	checkpoint("[uniLoader/gts9-5g] late_init reached -- driver_probe_all + print_splash survived\n");
	return 0;
}

struct board_data board_ops = {
	.name = "samsung-gts9-5g",
	.ops = {
		.early_init = gts9_5g_early_init,
		.late_init = gts9_5g_late_init,
	},
	.quirks = 0,
};
