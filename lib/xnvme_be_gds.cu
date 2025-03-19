// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <xnvme_be_gds.h>

struct xnvme_be_mixin g_xnvme_be_mixin_gds[] = {
	{
		.mtype = XNVME_BE_ASYNC,
		.name = "gds",
		.descr = "Use the gds NVMe driver",
		.async = &g_xnvme_be_gds_async,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_SYNC,
		.name = "gds",
		.descr = "Use the gds NVMe driver",
		.sync = &g_xnvme_be_gds_sync,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_ADMIN,
		.name = "gds",
		.descr = "Use the gds NVMe driver",
		.admin = &g_xnvme_be_gds_admin,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_MEM,
		.name = "gpu",
		.descr = "Use buffers in GPU memory",
		.mem = &g_xnvme_be_gds_mem_gpu,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_MEM,
		.name = "cpu",
		.descr = "Use buffers in CPU memory",
		.mem = &g_xnvme_be_gds_mem_cpu,
		.check_support = xnvme_be_supported,
	},

	{
		.mtype = XNVME_BE_DEV,
		.name = "gds",
		.descr = "Use the gds NVMe driver",
		.dev = &g_xnvme_be_gds_dev,
		.check_support = xnvme_be_supported,
	},
};
#endif

struct xnvme_be xnvme_be_gds = {
	.async = XNVME_BE_NOSYS_QUEUE,
	.sync = XNVME_BE_NOSYS_SYNC,
	.admin = XNVME_BE_NOSYS_ADMIN,
	.dev = XNVME_BE_NOSYS_DEV,
	.attr =
		{
			.name = "gds",
#ifdef XNVME_BE_BAM_ENABLED
			.enabled = 1,
#endif
		},
	.mem = XNVME_BE_NOSYS_MEM,
	.state = {0},
#ifdef XNVME_BE_BAM_ENABLED
	.objs = g_xnvme_be_mixin_gds,
	.nobjs = sizeof g_xnvme_be_mixin_gds / sizeof *g_xnvme_be_mixin_gds,
#endif
};
