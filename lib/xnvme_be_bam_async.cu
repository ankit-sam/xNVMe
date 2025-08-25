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
#include <xnvme_be_bam.h>

int
xnvme_be_bam_queue_init(struct xnvme_queue *q, int XNVME_UNUSED(opts))
{
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)q;
	struct xnvme_dev *dev = queue->base.dev;
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)queue->base.dev->be.state;
	void *cq_buf, *sq_buf;
	struct local_admin *admin;
	int err, qid;

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
	queue->cq = (nvm_queue_t *) malloc(sizeof(nvm_queue_t));
	if (!queue->cq) {
			XNVME_DEBUG("FAILED: could not allocate memory for CQ");
			nvm_dma_unmap(queue->cq_mem);
			nvm_dma_unmap(queue->sq_mem);
			return -ENOMEM;
	}
	queue->sq = (nvm_queue_t *) malloc(sizeof(nvm_queue_t));
	if (!queue->sq) {
			XNVME_DEBUG("FAILED: could not allocate memory for SQ");
			nvm_dma_unmap(queue->cq_mem);
			nvm_dma_unmap(queue->sq_mem);
			free(queue->cq);
			return -ENOMEM;
	}
	pthread_mutex_lock(&admin->mutex);
	qid = xnvme_array_find_first_and_set(admin->qids, admin->n_qps);
	if (!qid) {
		err = -ENOMEM;
		XNVME_DEBUG("FAILED: could not find free queue slot, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}

	err = nvm_admin_cq_create(state->aq, queue->cq, qid, queue->cq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O completion queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		nvm_dma_unmap(queue->cq_mem);
		nvm_dma_unmap(queue->sq_mem);
		free(queue->cq);
		free(queue->sq);
		return err;
	}

	err = nvm_admin_sq_create(state->aq, queue->sq, queue->cq, qid, queue->sq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O submission queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		nvm_dma_unmap(queue->cq_mem);
		nvm_dma_unmap(queue->sq_mem);
		free(queue->cq);
		free(queue->sq);
		return err;
	}
	queue->qid = qid;

	pthread_mutex_unlock(&admin->mutex);

	return 0;
}

int
xnvme_be_bam_queue_term(struct xnvme_queue *q)
{
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)q;
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)queue->base.dev->be.state;
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
	admin->qids[queue->qid] = 0;
	pthread_mutex_unlock(&admin->mutex);

	nvm_dma_unmap(queue->cq_mem);
	nvm_dma_unmap(queue->sq_mem);
	free(queue->cq);
	free(queue->sq);
	return 0;
}

int
xnvme_be_bam_queue_poke(struct xnvme_queue *queue, uint32_t max)
{
	struct xnvme_queue_bam *q = (struct xnvme_queue_bam *)queue;
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

void
xnvme_be_bam_cmd_data(struct xnvme_queue_bam *q, void *dbuf, uint64_t dbuf_nbytes, nvm_dma_t *mem, nvm_cmd_t *cmd, uint32_t cmd_id)
{
		uint64_t ioaddr, offset, prp1, prp2 = 0;
		uint16_t prp_offset;
		uint64_t *prp_list;
		size_t n_pages;

		ioaddr = ((uint64_t)dbuf - (uint64_t)mem->vaddr) / mem->page_size;
		offset = ((uint64_t)dbuf - (uint64_t)mem->vaddr) % mem->page_size;
		n_pages = (dbuf_nbytes + mem->page_size - 1) / mem->page_size;
		prp1 = mem->ioaddrs[ioaddr] + offset;

		if (n_pages == 2) {
			prp2 = mem->ioaddrs[ioaddr+1];
		} else if (n_pages > 2) {
			prp_offset = (cmd_id % q->sq->qs) + 1;
			prp_list = (uint64_t *)NVM_DMA_OFFSET(q->sq_mem, prp_offset);
			prp2 = q->sq_mem->ioaddrs[prp_offset];
			for (size_t i = 1; i < n_pages; ++i) {
	      prp_list[i-1] = mem->ioaddrs[ioaddr+i];
	    }
		}
		nvm_cmd_data_ptr(cmd, prp1, prp2);
}

#if 0
int
xnvme_be_bam_async_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)ctx->async.queue;
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)queue->base.dev->be.state;
	uint32_t cmd_id = ((struct xnvme_cmd_ctx_entry *)ctx)->id;
	struct xnvme_be_bam_memory *m;
	nvm_cmd_t *cmd;
	int err;

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
		m = xnvme_be_bam_memory_find(state, dbuf);
		if (!m) {
			XNVME_DEBUG("WARNING: couldn't find memory in skiplist, creating new mapping");
			err = xnvme_be_bam_cpu_dma_map(state, &m, dbuf, dbuf_nbytes);
			if (err) {
				XNVME_DEBUG("FAILED: couldn't create dma mapping, err: %d", err);
				return err;
			}
		}
		xnvme_be_bam_cmd_data(queue, dbuf, dbuf_nbytes, m->mem, cmd, cmd_id);
	}

	nvm_sq_submit(queue->sq);
	queue->base.outstanding++;

	return 0;
}
#else
int
xnvme_be_bam_async_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_queue_bam *queue = (struct xnvme_queue_bam *)ctx->async.queue;
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)queue->base.dev->be.state;
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
#endif

int
xnvme_be_bam_async_cmd_iov(struct xnvme_cmd_ctx *ctx, struct iovec *dvec, size_t dvec_cnt,
			   size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	void *spdk_buf = dvec->iov_base;
	int rc;

	if (dvec_cnt != 1) {
		XNVME_DEBUG("FAILED: more than 1 vector required");
		return -EINVAL;
	}

	rc = xnvme_be_bam_async_cmd_io(ctx, spdk_buf, dbuf_nbytes, NULL, 0);

	return rc;
}
 
#endif

struct xnvme_be_async g_xnvme_be_bam_async = {
#ifdef XNVME_BE_BAM_ENABLED
	.cmd_io = xnvme_be_bam_async_cmd_io,
	.cmd_iov = xnvme_be_bam_async_cmd_iov,
	.poke = xnvme_be_bam_queue_poke,
	.wait = xnvme_be_nosys_queue_wait,
	.init = xnvme_be_bam_queue_init,
	.term = xnvme_be_bam_queue_term,
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
	.id = "bam",
};
