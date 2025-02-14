// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

__device__ int
xnvme_be_bam_sync_cmd_io(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes, void *XNVME_UNUSED(mbuf),
			   size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state*)ctx->dev->be.state;
	struct xnvme_be_bam_memory *m;
	nvm_queue_t *sq, *cq;
	nvm_cmd_t *cmd;
	uint64_t *ioaddrs;
	uint32_t pos, qid, cid, head, head_;
	uint64_t offset, remainder, prp1, prp2 = 0;

	if (lane_id() == 0) {
		qid = state->queue_counter.fetch_add(1, simt::memory_order_relaxed) % XNVME_BE_BAM_NQUEUES_MAX;
	}
	qid = __shfl_sync(0xFFFFFFFF, qid, 0);

	sq = &state->sq[qid];
	cq = &state->cq[qid];

	cid = get_cid(sq);
	ctx->cmd.common.cid = cid;
	cmd = (nvm_cmd_t *) &ctx->cmd;

	if (dbuf) {
		m = xnvme_be_bam_memory_find(state, dbuf);
		if (!m) {
			return -ENOENT;
		}

		if (dbuf_nbytes > state->ctrlr->page_size * 2) {
			return -EINVAL;
		}

		offset = ((uint64_t)dbuf - (uint64_t)m->mem->vaddr)/m->mem->page_size;
		remainder = (((uint64_t)dbuf - (uint64_t)m->mem->vaddr)%m->mem->page_size);
		ioaddrs = m->mem->ioaddrs;
		prp1 = ioaddrs[offset] + remainder;

		if (dbuf_nbytes > m->mem->page_size) {
			prp2 = prp1 + m->mem->page_size;
		}

		nvm_cmd_data_ptr(cmd, prp1, prp2);
	}

	sq_enqueue(sq, cmd);
	pos = cq_poll(cq, cid, &head, &head_);
	cq_dequeue(cq, pos, sq);
	put_cid(sq, cid);

	return 0;
}

#endif

struct xnvme_be_sync g_xnvme_be_bam_sync = {
#ifdef XNVME_BE_BAM_ENABLED
	.cmd_io = xnvme_be_bam_sync_cmd_io,
	.cmd_iov = xnvme_be_nosys_sync_cmd_iov,
#else
	.cmd_io = xnvme_be_nosys_sync_cmd_io,
	.cmd_iov = xnvme_be_nosys_sync_cmd_iov,
#endif
	.id = "bam",
};
