// SPDX-License-Identifier: GPL-2.0
/*
 * drivers/samsung/sec_debug_reclaim_memory.c
 *
 * Custom memory reclaimer
 * Recovers memory reserved for sec_debug
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 and
 * only version 2 as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */
#define pr_fmt(fmt) "SEC_DEBUG_MEM_RECLAIM: " fmt

#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/memblock.h>
#include <linux/of.h>
#include <linux/of_reserved_mem.h>
#include <linux/io.h>
#include <asm/page.h>

static int __init reclaim_sec_debug_ram(void)
{
	struct device_node *parent, *node;
	struct reserved_mem *res_mem;
	phys_addr_t paddr = 0;
	u64 size = 0;
	int ret;

	parent = of_find_node_by_path("/reserved-memory");
	if (!parent) {
		pr_err("Failed to find /reserved-memory tree node\n");
		return -EINVAL;
	}

	node = of_find_node_by_name(parent, "sec_debug_rdx_bootdev");
	if (!node) {
		pr_err("Target tracking block 'sec_debug_rdx_bootdev' not found. Already freed?\n");
		return -EINVAL;
	}

	res_mem = of_reserved_mem_lookup(node);
	if (!res_mem) {
		pr_err("Failed to lookup memory parameters from device tree node\n");
		return -EINVAL;
	}

	paddr = res_mem->base;
	size = (u64)res_mem->size;

	if (!paddr || !size) {
		pr_err("Invalid address table dimensions encountered (paddr: %pa, size: 0x%llx)\n", &paddr, size);
		return -EINVAL;
	}

	pr_info("Found isolated allocation block at %pa (Size: 0x%llx Bytes)\n", &paddr, size);

	memset(phys_to_virt(paddr), 0, size);

	ret = memblock_free(paddr, size);
	if (ret) {
		pr_err("memblock_free failed to unbind address mapping (ret: %d)\n", ret);
		return ret;
	}

	free_reserved_area(phys_to_virt(paddr), phys_to_virt(paddr) + size, -1, "reclaimed_vendor_ram");

	pr_info("Successfully recycled 0x%llx bytes (~%llu MB) back to system memory allocator!\n", size, (size / 1024 / 1024));
	return 0;
}

arch_initcall_sync(reclaim_sec_debug_ram);