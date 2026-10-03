// SPDX-License-Identifier: GPL-2.0
/*
 * Registers a "ramoops" platform device on the SM-X716B's sec_pmsg carve-out
 * (0x8_80900000, 2 MiB) at run time, for the kernel's built-in ramoops
 * driver.
 *
 * Why a module rather than a devicetree node: a board DTB carrying
 * compatible = "ramoops" on this region did not boot (2026-10-03: hard reset
 * right after ABL's ExitBootServices, before any console existed), and
 * Fedora's lockdown=integrity refuses ramoops' own mem_address parameter.
 * Loading this after boot keeps a failure of the region visible in the
 * sec-log console instead of losing the boot.
 *
 * DRAM here decays across this board's reset: bits flip, and when they flip
 * in a zone header ramoops calls the buffer invalid and wipes it.  So the
 * whole region is copied before ramoops sees it and kept readable at
 * /sys/kernel/debug/x716_ramoops/previous, corrupt header or not.
 */
#include <linux/debugfs.h>
#include <linux/io.h>
#include <linux/kmsg_dump.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/pstore_ram.h>
#include <linux/vmalloc.h>

#define X716_RAMOOPS_BASE	0x880900000ULL
#define X716_RAMOOPS_SIZE	0x200000

static struct ramoops_platform_data x716_ramoops_data = {
	.mem_address	= X716_RAMOOPS_BASE,
	.mem_size	= X716_RAMOOPS_SIZE,
	.record_size	= 0x40000,
	.console_size	= 0x100000,
	.pmsg_size	= 0x20000,
	.max_reason	= KMSG_DUMP_OOPS,
};

static struct platform_device *x716_ramoops_pdev;
static struct dentry *x716_ramoops_dir;
static struct debugfs_blob_wrapper x716_ramoops_previous;

static void x716_ramoops_snapshot(void)
{
	void *region, *copy;

	copy = vmalloc(X716_RAMOOPS_SIZE);
	if (!copy)
		return;

	region = memremap(X716_RAMOOPS_BASE, X716_RAMOOPS_SIZE, MEMREMAP_WB);
	if (!region) {
		vfree(copy);
		return;
	}
	memcpy(copy, region, X716_RAMOOPS_SIZE);
	memunmap(region);

	x716_ramoops_previous.data = copy;
	x716_ramoops_previous.size = X716_RAMOOPS_SIZE;
	x716_ramoops_dir = debugfs_create_dir("x716_ramoops", NULL);
	debugfs_create_blob("previous", 0400, x716_ramoops_dir,
			    &x716_ramoops_previous);
}

static int __init x716_ramoops_init(void)
{
	x716_ramoops_snapshot();

	x716_ramoops_pdev = platform_device_register_data(NULL, "ramoops", -1,
			&x716_ramoops_data, sizeof(x716_ramoops_data));
	if (IS_ERR(x716_ramoops_pdev)) {
		debugfs_remove_recursive(x716_ramoops_dir);
		vfree(x716_ramoops_previous.data);
		return PTR_ERR(x716_ramoops_pdev);
	}
	return 0;
}

static void __exit x716_ramoops_exit(void)
{
	platform_device_unregister(x716_ramoops_pdev);
	debugfs_remove_recursive(x716_ramoops_dir);
	vfree(x716_ramoops_previous.data);
}

module_init(x716_ramoops_init);
module_exit(x716_ramoops_exit);
MODULE_DESCRIPTION("SM-X716B ramoops region on the sec_pmsg carve-out");
MODULE_LICENSE("GPL");
