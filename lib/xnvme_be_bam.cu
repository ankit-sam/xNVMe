// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <xnvme_be_bam.h>

struct xnvme_be_mixin g_xnvme_be_mixin_bam[] = {
	{
		.mtype = XNVME_BE_ASYNC,
		.name = "bam",
		.descr = "Use the BaM NVMe driver",
		.async = &g_xnvme_be_bam_async,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_SYNC,
		.name = "bam",
		.descr = "Use the BaM NVMe driver",
		.sync = &g_xnvme_be_bam_sync,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_ADMIN,
		.name = "bam",
		.descr = "Use the BaM NVMe driver",
		.admin = &g_xnvme_be_bam_admin,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_MEM,
		.name = "bam",
		.descr = "Use libc malloc()/free() with sysconf for alignment",
		.mem = &g_xnvme_be_bam_mem,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_DEV,
		.name = "bam",
		.descr = "Use the BaM NVMe driver",
		.dev = &g_xnvme_be_bam_dev,
		.check_support = xnvme_be_supported,
	},
};
#endif

struct xnvme_be xnvme_be_bam = {
	.async = XNVME_BE_NOSYS_QUEUE,
	.sync = XNVME_BE_NOSYS_SYNC,
	.admin = XNVME_BE_NOSYS_ADMIN,
	.dev = XNVME_BE_NOSYS_DEV,
	.attr =
		{
			.name = "bam",
#ifdef XNVME_BE_BAM_ENABLED
			.enabled = 1,
#endif
		},
	.mem = XNVME_BE_NOSYS_MEM,
	.state = {0},
#ifdef XNVME_BE_BAM_ENABLED
	.objs = g_xnvme_be_mixin_bam,
	.nobjs = sizeof g_xnvme_be_mixin_bam / sizeof *g_xnvme_be_mixin_bam,
#endif
};
