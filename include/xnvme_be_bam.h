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

struct xnvme_be_bam_state {
	nvm_ctrl_t *ctrlr;
	nvm_admin_reference *aq;
	nvm_queue_t *sq;
	nvm_queue_t *cq;
	nvm_dma_t **sq_mem;
	nvm_dma_t **cq_mem;
	cudaStream_t stream;

	struct skiplist *list;
	struct xnvme_queue *sync_q;
	void *buf;
	uint16_t qid;
	simt::atomic<uint64_t, simt::thread_scope_device> queue_counter;

	uint8_t primary;
	uint16_t n_qps;
	uint8_t used_qids[32];
	uint8_t _rvds[3];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_be_bam_state) == XNVME_BE_STATE_NBYTES, "Incorrect size")

struct xnvme_be_bam_memory {
	nvm_dma_t *mem;
	struct skiplist_node list;
};

struct xnvme_queue_bam {
	struct xnvme_queue_base base;

	nvm_queue_t *sq;
	nvm_queue_t *cq;
	nvm_dma_t *cq_mem;
	nvm_dma_t *sq_mem;

	uint32_t qid;
	uint8_t _rsvd[196];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_queue_bam) == XNVME_BE_QUEUE_STATE_NBYTES,
		    "Incorrect size")

uint32_t
xnvme_array_find_first_and_set(uint8_t *qids, uint32_t nqps);

__device__ __host__ struct xnvme_be_bam_memory *
xnvme_be_bam_memory_find(struct xnvme_be_bam_state *state, void *buf);

__device__ int
xnvme_be_bam_gpu_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes,
			void *XNVME_UNUSED(mbuf), size_t XNVME_UNUSED(mbuf_nbytes));

void *
xnvme_be_bam_gpu_buf_alloc(const struct xnvme_dev *dev, size_t nbytes,
			   uint64_t *XNVME_UNUSED(phys));

void
xnvme_be_bam_gpu_buf_free(const struct xnvme_dev *dev, void *buf);

int
xnvme_be_bam_gpu_delete_queues(struct xnvme_dev *dev);

int
xnvme_be_bam_gpu_create_queues(struct xnvme_dev *dev, uint16_t qd, uint16_t n_qps);

void
xnvme_be_bam_cmd_data(struct xnvme_queue_bam *q, void *dbuf, uint64_t dbuf_nbytes, nvm_dma_t *mem,
		      nvm_cmd_t *cmd, uint32_t cmd_id);

int
xnvme_be_bam_cpu_dma_map(struct xnvme_be_bam_state *state, struct xnvme_be_bam_memory **m,
			 void *buf, size_t nbytes);

void
xnvme_be_bam_cpu_dma_unmap(struct skiplist_node *n);

extern struct xnvme_be_admin g_xnvme_be_bam_admin;
extern struct xnvme_be_sync g_xnvme_be_bam_sync;
extern struct xnvme_be_async g_xnvme_be_bam_async;
extern struct xnvme_be_mem g_xnvme_be_bam_mem;
extern struct xnvme_be_dev g_xnvme_be_bam_dev;

#endif /* __INTERNAL_XNVME_BE_BAM */
