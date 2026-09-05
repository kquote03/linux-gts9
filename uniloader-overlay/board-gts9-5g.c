/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Board file for the Samsung Galaxy Tab S9 5G (SM-X716B).
 *
 * UNTESTED / UNFLASHED. Deliberately minimal: no early_init/late_init and
 * no framebuffer device are needed for the Phase 1-3 bring-up MVP -- all
 * SoC/PMIC/UFS/pinctrl bring-up is the mainline Linux kernel's job (see
 * kernel/dts/sm8550-samsung-x716b.dts), not uniLoader's. Confirmed by
 * reading include/main/main.h's INITCALL() macro that both hooks are
 * genuinely optional (it null-checks before calling), and by
 * board/qemu/board-virt.c's own precedent of a devices-less board_data.
 */
#include <board.h>

struct board_data board_ops = {
	.name = "samsung-gts9-5g",
	.quirks = 0,
};
