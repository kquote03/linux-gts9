// SPDX-License-Identifier: GPL-2.0-only
/*
 * Console-less bring-up debug channel for the Samsung Galaxy Tab S9 5G
 * (SM-X716B): writes kernel console output into the same physical DRAM
 * region and on-disk format Samsung's stock downstream kernel uses for its
 * "sec_log_buf" persistent log, so that after a hang/panic/reboot, TWRP
 * (which is built from a Samsung-derived recovery kernel that already
 * knows how to read this region) can display the previous boot's kernel
 * log even with no UART cable and no display.
 *
 * This is a from-scratch reimplementation of the on-disk *format* only,
 * written after reading (not copying) Samsung's actual downstream driver
 * at drivers/samsung/debug/log_buf/{sec_log_buf_main.c,sec_log_buf.h} in
 * android_kernel_samsung_gts9 to confirm: the magic value, the header
 * layout, the devicetree compatible string a consumer node must use, and
 * the modulo-wrapping ring-buffer write algorithm. Everything else about
 * Samsung's driver (compression, debugfs, kprobe/vendor-hook logging
 * strategies, the ap_klog proc interface) is deliberately not replicated
 * -- this bring-up MVP only needs the write side of the simplest case.
 *
 * See docs/boot-strategy.md and docs/hardware-facts.md for how this fits
 * into the overall console-less debug strategy, including the important
 * caveat that this driver probes as an of_platform device (roughly
 * arch_initcall time) -- if a hang happens earlier than that (plausible,
 * given the sec_log_buf_main.c PMIC/UFS/pinctrl probe-hang risk this
 * project's plan already flags), this channel will have no data at all.
 * An earlycon-based capture is the fallback to build if that turns out to
 * matter in practice.
 */

#include <linux/console.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_address.h>
#include <linux/of_reserved_mem.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#define SEC_LOG_MAGIC 0x4d474f4c /* "LOGM", matches Samsung's stock format */

struct sec_log_buf_head {
	u32 boot_cnt;
	u32 magic;
	u32 idx;
	u32 prev_idx;
	char buf[];
};

struct x716_sec_log {
	struct sec_log_buf_head __iomem *head;
	size_t buf_size; /* size of head->buf[], i.e. region size minus the header */
	spinlock_t lock;
	struct console con;
};

static void x716_sec_log_write(struct console *co, const char *s, unsigned int count)
{
	struct x716_sec_log *log = container_of(co, struct x716_sec_log, con);
	unsigned long flags;
	u32 idx, off, first_len, second_len;

	spin_lock_irqsave(&log->lock, flags);

	idx = readl(&log->head->idx);
	off = idx % log->buf_size;
	first_len = min_t(u32, count, log->buf_size - off);
	memcpy_toio(&log->head->buf[off], s, first_len);

	second_len = count - first_len;
	if (second_len)
		memcpy_toio(&log->head->buf[0], s + first_len, second_len);

	writel(idx + count, &log->head->idx);

	spin_unlock_irqrestore(&log->lock, flags);
}

static struct x716_sec_log x716_sec_log = {
	.con = {
		.name = "x716seclog",
		.write = x716_sec_log_write,
		.flags = CON_ENABLED | CON_PRINTBUFFER,
		.index = -1,
	},
};

static int x716_sec_log_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *mem_np;
	struct reserved_mem *rmem;
	struct sec_log_buf_head __iomem *head;
	u32 magic;

	mem_np = of_parse_phandle(dev->of_node, "memory-region", 0);
	if (!mem_np)
		return -EINVAL;

	rmem = of_reserved_mem_lookup(mem_np);
	of_node_put(mem_np);
	if (!rmem) {
		dev_err(dev, "failed to look up memory-region\n");
		return -EINVAL;
	}

	/* MEMREMAP_WB, not ioremap: this region isn't marked no-map (matching
	 * Samsung's own stock DT, see kernel/dts/sm8550-samsung-x716b.dts), so
	 * it's ordinary cacheable system RAM as far as the rest of the kernel
	 * is concerned -- memremap is the correct way to get a mapping for
	 * driver use regardless of whether a region happens to already be in
	 * the kernel's linear map.
	 */
	head = memremap(rmem->base, rmem->size, MEMREMAP_WB);
	if (!head) {
		dev_err(dev, "failed to map sec_log_buf region\n");
		return -ENOMEM;
	}

	x716_sec_log.head = (struct sec_log_buf_head __iomem *)head;
	x716_sec_log.buf_size = rmem->size - offsetof(struct sec_log_buf_head, buf);
	spin_lock_init(&x716_sec_log.lock);

	magic = readl(&x716_sec_log.head->magic);
	if (magic != SEC_LOG_MAGIC) {
		dev_info(dev, "no valid sec_log_buf found (magic=0x%x), initializing fresh\n", magic);
		writel(SEC_LOG_MAGIC, &x716_sec_log.head->magic);
		writel(0, &x716_sec_log.head->idx);
		writel(0, &x716_sec_log.head->prev_idx);
		writel(0, &x716_sec_log.head->boot_cnt);
	} else {
		/* Valid buffer from a previous boot (or this same boot's earlier
		 * stage) -- leave idx as-is and keep appending, matching Samsung's
		 * own ring-buffer behavior. Whatever is in buf[] up to idx right
		 * now is exactly what a subsequent TWRP boot's last_kmsg reader
		 * would show if we stopped here, before this driver has written
		 * anything of its own -- i.e. it's the previous boot's tail.
		 */
		writel(readl(&x716_sec_log.head->boot_cnt) + 1, &x716_sec_log.head->boot_cnt);
	}

	register_console(&x716_sec_log.con);
	dev_info(dev, "sec-log console registered (%zu byte ring buffer)\n", x716_sec_log.buf_size);

	return 0;
}

static const struct of_device_id x716_sec_log_match[] = {
	{ .compatible = "samsung,kernel_log_buf" },
	{}
};
MODULE_DEVICE_TABLE(of, x716_sec_log_match);

static struct platform_driver x716_sec_log_driver = {
	.driver = {
		.name = "x716-sec-log",
		.of_match_table = x716_sec_log_match,
	},
	.probe = x716_sec_log_probe,
};
module_platform_driver(x716_sec_log_driver);

MODULE_DESCRIPTION("Samsung Galaxy Tab S9 5G (SM-X716B) sec-log bring-up console");
MODULE_LICENSE("GPL");
