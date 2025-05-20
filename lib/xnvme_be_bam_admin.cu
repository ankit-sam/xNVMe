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
xnvme_be_bam_sync_cmd_admin(struct xnvme_cmd_ctx *ctx, void *dbuf, size_t dbuf_nbytes,
			     void *XNVME_UNUSED(mbuf), size_t XNVME_UNUSED(mbuf_nbytes))
{
	struct xnvme_be_bam_state *state = (xnvme_be_bam_state *)ctx->dev->be.state;
	struct xnvme_be_bam_memory *m;
	struct local_admin *admin;
	nvm_cmd_t *cmd = (nvm_cmd_t *)&ctx->cmd;
	nvm_cpl_t *cpl = (nvm_cpl_t *)&ctx->cpl;
	uint64_t offset, remainder, prp1, prp2;
	int err;

	if (dbuf) {
		m = xnvme_be_bam_memory_find(state, dbuf);
		if (!m) {
			XNVME_DEBUG("FAILED: couldn't find memory in skiplist");
			return -ENOENT;
		}

		if (dbuf_nbytes > state->ctrlr->page_size * 2) {
			XNVME_DEBUG("FAILED: more than 2 PRP entries required");
			return -EINVAL;
		}

		offset = ((uint64_t)dbuf - (uint64_t)m->mem->vaddr)/m->mem->page_size;
		remainder = (((uint64_t)dbuf - (uint64_t)m->mem->vaddr)%m->mem->page_size);
		prp1 = m->mem->ioaddrs[offset] + remainder;
		if (dbuf_nbytes > state->ctrlr->page_size) {
			prp2 = prp1 + state->ctrlr->page_size;
		}

		nvm_cmd_data_ptr(cmd, prp1, prp2);
	}

	admin = (struct local_admin *)((uint8_t *)state->buf + state->ctrlr->page_size * 3);
	pthread_mutex_lock(&admin->mutex);

	err = nvm_raw_rpc(state->aq, cmd, cpl);
	pthread_mutex_unlock(&admin->mutex);
	if (!nvm_ok(err)) {
		XNVME_DEBUG("FAILED: nvm_raw_rpc(), err: %s", nvm_strerror(err));
		return err;
	}

	return 0;
}
#endif

struct xnvme_be_admin g_xnvme_be_bam_admin = {
#ifdef XNVME_BE_BAM_ENABLED
	.cmd_admin = xnvme_be_bam_sync_cmd_admin,
	.cmd_pseudo = xnvme_be_nosys_sync_cmd_pseudo,
#else
	.cmd_admin = xnvme_be_nosys_sync_cmd_admin,
	.cmd_pseudo = xnvme_be_nosys_sync_cmd_pseudo,
#endif
	.id = "bam",
};
