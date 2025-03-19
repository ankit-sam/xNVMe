// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

#ifndef __INTERNAL_XNVME_BE_GDS_H
#define __INTERNAL_XNVME_BE_GDS_H
extern "C" {
#include "ccan/container_of/container_of.h"
}

#include <errno.h>
#include <pthread.h>

#include <skiplist.h>
#include <nvm_ctrl.h>
#include <nvm_types.h>
#include <nvm_queue.h>
#include <nvm_util.h>
#include <nvm_admin.h>
#include <nvm_error.h>
#include <nvm_cmd.h>
#include <nvm_rpc.h>
#include <ctrl.h>
#include <buffer.h>
#include <nvm_aq.h>
#include <nvm_dma.h>
#include <queue.h>
#include <nvm_parallel_queue.h>
#include <util.h>

#include <xnvme_be.h>
#include <xnvme_queue.h>

#define XNVME_BE_GDS_NQUEUES_MAX 128

struct xnvme_be_gds_state {
	nvm_ctrl_t *ctrlr;
	nvm_admin_reference *aq;
	nvm_queue_t *sq;
	nvm_queue_t *cq;
	struct skiplist *list;
	uint8_t qid;

	uint8_t _rvds[87];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_be_gds_state) == XNVME_BE_STATE_NBYTES, "Incorrect size")

struct xnvme_be_gds_memory {
	nvm_dma_t *mem;
	struct skiplist_node list;
};

struct xnvme_be_gds_memory *
xnvme_be_gds_memory_find(struct xnvme_be_gds_state *state, void *buf);

extern struct xnvme_be_admin g_xnvme_be_gds_admin;
extern struct xnvme_be_sync g_xnvme_be_gds_sync;
extern struct xnvme_be_async g_xnvme_be_gds_async;
extern struct xnvme_be_mem g_xnvme_be_gds_mem_gpu;
extern struct xnvme_be_mem g_xnvme_be_gds_mem_cpu;
extern struct xnvme_be_dev g_xnvme_be_gds_dev;

#endif /* __INTERNAL_XNVME_BE_GDS */
