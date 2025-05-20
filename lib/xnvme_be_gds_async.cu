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
	struct local_admin *admin;
	int err, qid = state->qid++, qloc = state->qloc++;

	// Whether the controller requires contiguous phys mem for queues
	bool contiguous_queues = !!_RB(*_REG(state->ctrlr->mm_ptr, 0x0000, 64), 16, 16);

	// NVMe queue capacity must be one larger than the requested capacity
	// since only n-1 slots in an NVMe queue may be used
	int qd = queue->base.capacity + 1;

	if (qid >= 31) {
		XNVME_DEBUG("FAILED: can't allocate any more I/O queues");
		return -EINVAL;
	}

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

	err = posix_memalign(&sq_buf, 4096, qd * (sizeof(nvm_cmd_t) + 4096));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		nvm_dma_unmap(queue->cq_mem);
		return err;
	}

	err = nvm_dma_map_host(&queue->sq_mem, state->ctrlr, sq_buf, qd * (sizeof(nvm_cmd_t) + 4096));
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		nvm_dma_unmap(queue->cq_mem);
		free(sq_buf);
		return err;
	}

	admin = (struct local_admin *)((uint8_t *)state->buf + state->ctrlr->page_size * 3);
	pthread_mutex_lock(&admin->mutex);

	err = nvm_admin_cq_create(state->aq, &state->cq[qloc], qid, queue->cq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O completion queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}

	err = nvm_admin_sq_create(state->aq, &state->sq[qloc], &state->cq[qloc], qid, queue->sq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O submission queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}
	pthread_mutex_unlock(&admin->mutex);

	queue->cq = &state->cq[qloc];
	queue->sq = &state->sq[qloc];

	return 0;
}

int
xnvme_be_gds_queue_term(struct xnvme_queue *q)
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)q;
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state*)queue->base.dev->be.state;
	struct local_admin *admin;
	int err;

	admin = (struct local_admin *)((uint8_t *)state->buf + state->ctrlr->page_size * 3);
	pthread_mutex_lock(&admin->mutex);

	err = nvm_admin_sq_delete(state->aq, queue->sq, queue->cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O submission queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}

	err = nvm_admin_cq_delete(state->aq, queue->cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O completion queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}
	pthread_mutex_unlock(&admin->mutex);

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
		nvm_sq_update(q->sq);

		reaped++;

		ctx = (struct xnvme_cmd_ctx *)&queue->pool_storage[cpl->cid];
		memcpy(&ctx->cpl, cpl, sizeof(ctx->cpl));
		ctx->async.cb(ctx, ctx->async.cb_arg);
		nvm_cq_update(q->cq);
		queue->base.outstanding--;

	} while (reaped < max);

	return reaped;
}

int
xnvme_be_gds_async_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)ctx->async.queue;
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state*)queue->base.dev->be.state;
	uint32_t cmd_id = ((struct xnvme_cmd_ctx_entry *)ctx)->id;
	nvm_cmd_t *cmd;
	nvm_dma_t *mem;
	int err;
	uint64_t offset;
	size_t n_pages;
	uint16_t prp_list;

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
		err = nvm_dma_map_host(&mem, state->ctrlr, dbuf, dbuf_nbytes);
		if (err) {
			XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
			return -ENOMEM;
		}

		prp_list = (cmd_id % queue->sq->qs) + 1;
		offset = ((uint64_t)dbuf - (uint64_t)mem->vaddr) / mem->page_size;

		n_pages = dbuf_nbytes / mem->page_size;
		nvm_cmd_data1(cmd, mem->page_size, n_pages, NVM_DMA_OFFSET(queue->sq_mem, prp_list),
			queue->sq_mem->ioaddrs[prp_list], &mem->ioaddrs[offset]);

		nvm_dma_unmap(mem);
	}

	nvm_sq_submit(queue->sq);
	queue->base.outstanding++;

	return 0;
}

int
xnvme_be_gds_async_cmd_iov(struct xnvme_cmd_ctx *ctx, struct iovec *dvec, size_t dvec_cnt,
			   size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)ctx->async.queue;
	void *buf = NULL;
	void *spdk_buf = dvec->iov_base;
	int rc;

	if (dvec_cnt != 1) {
		XNVME_DEBUG("FAILED: more than 1 vector required");
		return -EINVAL;
	}

	rc = xnvme_be_gds_async_cmd_io(ctx, spdk_buf, dbuf_nbytes, NULL, 0);

	return rc;
}

#endif

struct xnvme_be_async g_xnvme_be_gds_async = {
#ifdef XNVME_BE_BAM_ENABLED
	.cmd_io = xnvme_be_gds_async_cmd_io,
	.cmd_iov = xnvme_be_gds_async_cmd_iov,
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
