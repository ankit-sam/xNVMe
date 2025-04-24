// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <xnvme_dev.h>
#include <xnvme_queue.h>
#include <xnvme_be_gds.h>

struct xnvme_queue_gds {
	struct xnvme_queue_base base;

	nvm_queue_t *sq;
	nvm_queue_t *cq;
	nvm_dma_t *cq_mem;
	nvm_dma_t *sq_mem;

	uint8_t _rsvd[200];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_queue_gds) == XNVME_BE_QUEUE_STATE_NBYTES,
		    "Incorrect size")

int
xnvme_be_gds_queue_init(struct xnvme_queue *q, int XNVME_UNUSED(opts))
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)q;
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state*)queue->base.dev->be.state;
	void *cq_buf, *sq_buf;
	int err, qid = ++state->qid;

	// Whether the controller requires contiguous phys mem for queues
	bool contiguous_queues = !!_RB(*_REG(state->ctrlr->mm_ptr, 0x0000, 64), 16, 16);

	// NVMe queue capacity must be one larger than the requested capacity
	// since only n-1 slots in an NVMe queue may be used
	int qd = queue->base.capacity + 1;

	err = posix_memalign(&cq_buf, 4096, qd*sizeof(nvm_cpl_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}

	err = nvm_dma_map_host(&queue->cq_mem, state->ctrlr, cq_buf, qd*sizeof(nvm_cpl_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(cq_buf);
		return err;
	}

	if (contiguous_queues && !queue->cq_mem->contiguous) {
		XNVME_DEBUG("FAILED: controller requires contiguous memory for queues, but CQ mem is not contiguous");
		nvm_dma_unmap(queue->cq_mem);
		return -ENOMEM;
	}

	err = posix_memalign(&sq_buf, 4096, qd*sizeof(nvm_cmd_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		nvm_dma_unmap(queue->cq_mem);
		return err;
	}

	err = nvm_dma_map_host(&queue->sq_mem, state->ctrlr, sq_buf, qd*sizeof(nvm_cmd_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		nvm_dma_unmap(queue->cq_mem);
		free(sq_buf);
		return err;
	}

	if (contiguous_queues && !queue->sq_mem->contiguous) {
		XNVME_DEBUG("FAILED: controller requires contiguous memory for queues, but SQ mem is not contiguous");
		nvm_dma_unmap(queue->cq_mem);
		nvm_dma_unmap(queue->sq_mem);
		return -ENOMEM;
	}

	err = nvm_admin_cq_create(state->aq, &state->cq[qid], qid, queue->cq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O completion queue, err: %d", err);
		return err;
	}

	err = nvm_admin_sq_create(state->aq, &state->sq[qid], &state->cq[qid], qid, queue->sq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O submission queue, err: %d", err);
		return err;
	}

	queue->cq = &state->cq[qid];
	queue->sq = &state->sq[qid];

	return 0;
}

int
xnvme_be_gds_queue_term(struct xnvme_queue *q)
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)q;
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state*)queue->base.dev->be.state;
	int err;

	err = nvm_admin_sq_delete(state->aq, queue->sq, queue->cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O submission queue, err: %d", err);
		return err;
	}

	err = nvm_admin_cq_delete(state->aq, queue->cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O completion queue, err: %d", err);
		return err;
	}

	nvm_dma_unmap(queue->cq_mem);
	nvm_dma_unmap(queue->sq_mem);
	return 0;
}

int
xnvme_be_gds_queue_poke(struct xnvme_queue *queue, uint32_t max)
{
	struct xnvme_queue_gds *q = (struct xnvme_queue_gds *)queue;
	struct xnvme_cmd_ctx *ctx;
	struct xnvme_spec_cpl *cpl;

	unsigned int reaped = 0;

	if (!max) {
		max = queue->base.outstanding;
	}

	do {
		cpl = (struct xnvme_spec_cpl *)nvm_cq_dequeue(q->cq);
		if (!cpl) {
			break;
		}

		reaped++;

		ctx = (struct xnvme_cmd_ctx *)&queue->pool_storage[cpl->cid];
		memcpy(&ctx->cpl, cpl, sizeof(ctx->cpl));
		ctx->async.cb(ctx, ctx->async.cb_arg);

	} while (reaped < max);

	queue->base.outstanding -= reaped;

	if (reaped) {
		nvm_cq_update(q->cq);
		nvm_sq_update(q->sq);
	}

	return reaped;
}

int
xnvme_be_gds_async_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)ctx->async.queue;
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state*)queue->base.dev->be.state;
	uint32_t cmd_id = ((struct xnvme_cmd_ctx_entry *)ctx)->id;
	struct xnvme_be_gds_memory *m;
	nvm_cmd_t *cmd;
	uint64_t offset, remainder, prp1, prp2 = 0;

	if (queue->base.outstanding == queue->base.capacity) {
		XNVME_DEBUG("FAILED: queue is full");
		return -EBUSY;
	}

	ctx->cmd.common.cid = cmd_id;
	cmd = nvm_sq_enqueue(queue->sq);
	if (!cmd) {
		XNVME_DEBUG("FAILED: queue full, mismatch between xNVMe queue and libnvm queue");
		return -EBUSY;
	}
	*cmd = *((nvm_cmd_t *)&ctx->cmd);

	if (dbuf) {
		m = xnvme_be_gds_memory_find(state, dbuf);
		if (!m) {
			XNVME_DEBUG("FAILED: couldn't find memory in skiplist");
			return -ENOENT;
		}

		if (dbuf_nbytes > m->mem->page_size * 2) {
			XNVME_DEBUG("FAILED: more than 2 PRP entries required");
			return -EINVAL;
		}

		offset = ((uint64_t)dbuf - (uint64_t)m->mem->vaddr)/m->mem->page_size;
		remainder = (((uint64_t)dbuf - (uint64_t)m->mem->vaddr)%m->mem->page_size);
		prp1 = m->mem->ioaddrs[offset] + remainder;
		if (dbuf_nbytes > m->mem->page_size) {
			prp2 = prp1 + m->mem->page_size;
		}

		nvm_cmd_data_ptr(cmd, prp1, prp2);
	}

	nvm_sq_submit(queue->sq);
	queue->base.outstanding++;

	return 0;
}

#endif

struct xnvme_be_async g_xnvme_be_gds_async = {
#ifdef XNVME_BE_BAM_ENABLED
	.cmd_io = xnvme_be_gds_async_cmd_io,
	.cmd_iov = xnvme_be_nosys_queue_cmd_iov,
	.poke = xnvme_be_gds_queue_poke,
	.wait = xnvme_be_nosys_queue_wait,
	.init = xnvme_be_gds_queue_init,
	.term = xnvme_be_gds_queue_term,
	.get_completion_fd = xnvme_be_nosys_queue_get_completion_fd,
#else
	.cmd_io = xnvme_be_nosys_queue_cmd_io,
	.cmd_iov = xnvme_be_nosys_queue_cmd_iov,
	.poke = xnvme_be_nosys_queue_poke,
	.wait = xnvme_be_nosys_queue_wait,
	.init = xnvme_be_nosys_queue_init,
	.term = xnvme_be_nosys_queue_term,
	.get_completion_fd = xnvme_be_nosys_queue_get_completion_fd,
#endif
	.id = "gds",
};
