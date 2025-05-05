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
	uint8_t qid;
	uint8_t host;

	uint8_t rsvd1[6];

	nvm_queue_t *sq;
	nvm_queue_t *cq;
	nvm_dma_t *cq_mem;
	nvm_dma_t *sq_mem;

	uint8_t _rsvd[192];
};
XNVME_STATIC_ASSERT(sizeof(struct xnvme_queue_gds) == XNVME_BE_QUEUE_STATE_NBYTES,
		    "Incorrect size")

static int
gds_device_queue_init(struct xnvme_queue *q)
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)q;
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state*)queue->base.dev->be.state;
	void *cq_buf, *sq_buf;
	void *cq_db, *sq_db;
	int err, qid = ++state->qid;
	nvm_queue_t *sq = &state->sq[qid], *cq = &state->cq[qid];
	// NVMe queue capacity must be one larger than the requested capacity
	// since only n-1 slots in an NVMe queue may be used
	int qd = queue->base.capacity + 1;

	XNVME_DEBUG("qid %u, qd %u", qid, qd);
	// create CQ
	err = cudaMalloc(&cq_buf, NVM_PAGE_ALIGN(qd*sizeof(nvm_cpl_t), 1 << 16)); //align to 64k
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}

	err = nvm_dma_map_device(&queue->cq_mem, state->ctrlr, cq_buf, qd*sizeof(nvm_cpl_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(cq_buf);
		return err;
	}

	err = nvm_admin_cq_create(state->aq, cq, qid, queue->cq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O completion queue, err: %d", err);
		return err;
	}

	err = cudaHostGetDevicePointer(&cq_db, (void *)cq->db, 0);
	if (err) {
		XNVME_DEBUG("FAILED: could not get device pointer, err: %d", err);
		return err;
	}
	cq->db = (volatile uint32_t *) cq_db;

	err = cudaMalloc(&cq->head_mark, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}
	err = cudaMalloc(&cq->pos_locks, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}
	cq->qs_minus_1 = qd - 1;
	cq->qs_log2 = (uint32_t) XNVME_ILOG2(qd);

	// create SQ
	err = cudaMalloc(&sq_buf, NVM_PAGE_ALIGN(qd*sizeof(nvm_cmd_t), 1 << 16)); //align to 64k
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}

	err = nvm_dma_map_device(&queue->sq_mem, state->ctrlr, sq_buf, qd*sizeof(nvm_cmd_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(sq_buf);
		return err;
	}

	err = nvm_admin_sq_create(state->aq, sq, cq, qid, queue->sq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O submission queue, err: %d", err);
		return err;
	}

	err = cudaHostGetDevicePointer(&sq_db, (void *)sq->db, 0);
	if (err) {
		XNVME_DEBUG("FAILED: could not get device pointer, err: %d", err);
		return err;
	}
	sq->db = (volatile uint32_t *) sq_db;

	err = cudaMalloc(&sq->cid, (1<<16) * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}
	err = cudaMalloc(&sq->tickets, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}
	err = cudaMalloc(&sq->tail_mark, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}
	sq->qs_minus_1 = qd - 1;
	sq->qs_log2 = (uint32_t) XNVME_ILOG2(qd);

	queue->host = 0;
	queue->qid = qid;
	queue->cq = cq;
	queue->sq = sq;

	return 0;
}

static int
gds_host_queue_init(struct xnvme_queue *q)
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

	queue->host = 1;
	queue->qid = qid;
	queue->cq = &state->cq[qid];
	queue->sq = &state->sq[qid];

	return 0;
}

int
xnvme_be_gds_queue_init(struct xnvme_queue *q, int opts)
{
	int err;

	if (opts) {
		err = gds_device_queue_init(q);
		XNVME_DEBUG("Allocated qpair in device (GPU) memory");
	} else {
		err = gds_host_queue_init(q);
		XNVME_DEBUG("Allocated qpair in host memory");
	}

	return err;
}

int
gds_host_queue_term(struct xnvme_queue *q)
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
gds_device_queue_term(struct xnvme_queue *q)
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)q;
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state*)queue->base.dev->be.state;
	nvm_queue_t *sq = queue->sq, *cq = queue->cq;
	int err;

	cudaFree(sq->cid);
	cudaFree(sq->tickets);
	cudaFree(sq->tail_mark);

	cudaFree(cq->pos_locks);
	cudaFree(cq->head_mark);

	err = nvm_admin_sq_delete(state->aq, sq, cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O submission queue, err: %d", err);
		return err;
	}

	err = nvm_admin_cq_delete(state->aq, cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O completion queue, err: %d", err);
		return err;
	}

	nvm_dma_unmap(queue->cq_mem);
	nvm_dma_unmap(queue->sq_mem);

	return 0;
}

int
xnvme_be_gds_queue_term(struct xnvme_queue *q)
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)q;
	int err;

	if (queue->host) {
		err = gds_host_queue_term(q);
		XNVME_DEBUG("Freed qpair from host memory");
	} else {
		err = gds_device_queue_term(q);
		XNVME_DEBUG("Freed qpair from device (GPU) memory");
	}

	return err;
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

int
xnvme_be_gds_async_cmd_iov(struct xnvme_cmd_ctx *ctx, struct iovec *dvec, size_t dvec_cnt,
			   size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_queue_gds *queue = (struct xnvme_queue_gds *)ctx->async.queue;
	void *buf = NULL;
	void *spdk_buf = dvec->iov_base;
	struct xnvme_spec_cpl *cpl;
	int rc;

	if (dvec_cnt != 1) {
		XNVME_DEBUG("FAILED: more than 1 vector required");
		return -EINVAL;
	}

	buf = ctx->dev->be.mem.buf_alloc(ctx->dev, dbuf_nbytes, NULL);
	if (buf && ctx->cmd.common.opcode == XNVME_SPEC_NVM_OPC_WRITE) {
		XNVME_DEBUG("Copying :%u bytes from: %p to %p", dbuf_nbytes, spdk_buf, buf);
		memcpy(buf, spdk_buf, dbuf_nbytes);
	}

	rc = xnvme_be_gds_async_cmd_io(ctx, buf, dbuf_nbytes, NULL, 0);
	if (rc) {
		XNVME_DEBUG("error: %d", rc);
		return rc;
	} else {
		do {
again:
			cpl = (struct xnvme_spec_cpl *)nvm_cq_poll(queue->cq);
			if (!cpl) {
				usleep(1);
				goto again;
			}

			if (cpl->status.sc || cpl->status.sct) {
				XNVME_DEBUG("cid: %d, sc: %x, sct: %x", cpl->cid, cpl->status.sc, cpl->status.sct);
				return -EINVAL;
			}
			if (buf && ctx->cmd.common.opcode == XNVME_SPEC_NVM_OPC_READ) {
				XNVME_DEBUG("Copying :%u bytes from: %p to %p", dbuf_nbytes, buf, spdk_buf);
				memcpy(spdk_buf, buf, dbuf_nbytes);
			}

			ctx->dev->be.async.poke(ctx->async.queue, 0);
			break;
		} while (1);
	}

	ctx->dev->be.mem.buf_free(ctx->dev, buf);
	return 0;
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
