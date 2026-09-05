/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright (c) 2025, Ivaylo Ivanov <ivo.ivanov.ivanov1@gmail.com>
 *
 * BRING-UP DIAGNOSTIC COPY for the Samsung Galaxy Tab S9 5G (SM-X716B):
 * identical to upstream uniLoader's arch/aarch64/reloc.S except for two
 * added raw-assembly checkpoints that write directly into the physical
 * sec_log_buf region/format (see kernel/drivers/samsung-x716-sec-log.c
 * and uniloader-overlay/board-gts9-5g.c's checkpoint() for the same
 * format used from C) -- checkpoint A ("CKPA") right at _reloc_entry's
 * start, checkpoint B ("CKPB") right before the final jump to _entry
 * (reached either via the same-address shortcut or after the copy loop
 * completes). Both explicitly set magic + idx (not just poke a byte
 * pattern) so /proc/last_kmsg -- which only exposes buf[0..idx) -- will
 * actually show them.
 *
 * This runs before any C runtime or valid stack exists, hence raw
 * MOVZ/MOVK/STR rather than a function call. Added because three real
 * flash attempts all failed with zero signal reaching even uniLoader's
 * earliest C code (main()'s early_init hook) -- this bisects whether the
 * crash is in this relocation copy specifically. Remove once the real
 * root cause is found.
 */
#include "asmdefs.h"

#ifdef CONFIG_LINUX_KRNL_HEADER_IMG
#include "linux-kernel-image-header.h"
#endif

.extern _reloc_size
.extern _start

ENTRY_ALIAS(_head)
#ifdef CONFIG_LINUX_KRNL_HEADER_IMG
	linux_image_header _reloc_entry
#else
	adr	x1, _relocated_uni
	b	 _reloc_entry
#endif

ENTRY_ALIAS(_rel_stack_base)
	.quad _start

ENTRY_ALIAS(_rel_stack_size)
	.quad _reloc_size

ENTRY_ALIAS( _reloc_entry)
	/* checkpoint A: reloc_entry reached at all. magic @ 0x880200004,
	 * "CKPA" @ 0x880200010 (buf[0:4]), idx=4 @ 0x880200008. */
	movz	x0, #0x0004
	movk	x0, #0x8020, lsl #16
	movk	x0, #0x0008, lsl #32
	movz	w1, #0x4f4c
	movk	w1, #0x4d47, lsl #16
	str	w1, [x0]

	movz	x0, #0x0010
	movk	x0, #0x8020, lsl #16
	movk	x0, #0x0008, lsl #32
	movz	w1, #0x4b43
	movk	w1, #0x4150, lsl #16
	str	w1, [x0]

	movz	x0, #0x0008
	movk	x0, #0x8020, lsl #16
	movk	x0, #0x0008, lsl #32
	movz	w1, #0x0004
	str	w1, [x0]

	adr	x4, _start
	ldr	x5, _rel_stack_base
	cmp	x4, x5
	beq	_entry
	ldr	x6,  _rel_stack_size

_copy:
	ldp	x2, x3, [x4], #16
	stp	x2, x3, [x5], #16
	subs	x6, x6, #16
	b.ne	_copy
	ldr	x5, _rel_stack_base

_entry:
	/* checkpoint B: about to jump to _start (via shortcut or after
	 * copy). "CKPB" @ 0x880200014 (buf[4:8]), idx=8. */
	movz	x0, #0x0014
	movk	x0, #0x8020, lsl #16
	movk	x0, #0x0008, lsl #32
	movz	w1, #0x4b43
	movk	w1, #0x4250, lsl #16
	str	w1, [x0]

	movz	x0, #0x0008
	movk	x0, #0x8020, lsl #16
	movk	x0, #0x0008, lsl #32
	movz	w1, #0x0008
	str	w1, [x0]

	br	x5

_dead: /* we should never get here */
	b	_dead

ENTRY_ALIAS(_relocated_uni)
