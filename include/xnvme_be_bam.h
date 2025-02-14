// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

#ifndef __INTERNAL_XNVME_BE_BAM_H
#define __INTERNAL_XNVME_BE_BAM_H
extern "C" {
#include <ccan/container_of/container_of.h>
}

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
#include <simt/atomic>
#include <nvm_parallel_queue.h>
#include <util.h>

#include <skiplist.h>

#include <xnvme_be.h>
#include <xnvme_queue.h>

#define XNVME_BE_BAM_NQUEUES_MAX 128
#define XNVME_BE_BAM_QD_MAX      1024

struct xnvme_be_bam_state {
	nvm_ctrl_t *ctrlr;
	nvm_admin_reference *aq;
	nvm_queue_t *sq;
	nvm_queue_t *cq;
	nvm_dma_t **sq_mem;
	nvm_dma_t **cq_mem;

	struct skiplist *list;
	simt::atomic<uint64_t, simt::thread_scope_device> queue_counter;

	uint8_t _rvds[64];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_be_bam_state) == XNVME_BE_STATE_NBYTES, "Incorrect size")

struct xnvme_be_bam_memory {
	nvm_dma_t *mem;
	struct skiplist_node list;
};

__device__ __host__ struct xnvme_be_bam_memory *
xnvme_be_bam_memory_find(struct xnvme_be_bam_state *state, void *buf);

__device__ int
xnvme_be_bam_sync_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes,
			 void *XNVME_UNUSED(mbuf), size_t XNVME_UNUSED(mbuf_nbytes));

extern struct xnvme_be_admin g_xnvme_be_bam_admin;
extern struct xnvme_be_sync g_xnvme_be_bam_sync;
extern struct xnvme_be_async g_xnvme_be_bam_async;
extern struct xnvme_be_mem g_xnvme_be_bam_mem;
extern struct xnvme_be_dev g_xnvme_be_bam_dev;

#endif /* __INTERNAL_XNVME_BE_BAM */
