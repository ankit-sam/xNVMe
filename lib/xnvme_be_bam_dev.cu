// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <fcntl.h>
#include <xnvme_dev.h>
#include <xnvme_queue.h>
#include <xnvme_be_bam.h>

int g_shmid_shared;

int
xnvme_be_bam_gpu_queue_term(struct xnvme_be_bam_state *state, uint16_t pos)
{
	nvm_queue_t *sq = &state->sq[pos], *cq = &state->cq[pos];
	nvm_dma_t *sq_mem = state->sq_mem[pos], *cq_mem = state->cq_mem[pos];
	struct local_admin *admin = (struct local_admin *)((uint8_t *)state->buf + state->ctrlr->page_size * 3);
	int err;

	cudaFree(sq->cid);
	cudaFree(sq->tickets);
	cudaFree(sq->tail_mark);

	cudaFree(cq->pos_locks);
	cudaFree(cq->head_mark);

	pthread_mutex_lock(&admin->mutex);
	err = nvm_admin_sq_delete(state->aq, sq, cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O submission queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}

	err = nvm_admin_cq_delete(state->aq, cq);
	if (err) {
		XNVME_DEBUG("FAILED: could not delete I/O completion queue, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}

	admin->qids[state->used_qids[pos]] = 0;
	state->used_qids[pos] = 0;
	pthread_mutex_unlock(&admin->mutex);
	nvm_dma_unmap(cq_mem);
	nvm_dma_unmap(sq_mem);

	return 0;
}

int
xnvme_be_bam_gpu_queue_init(struct xnvme_be_bam_state *state, uint16_t qd, uint16_t pos)
{
	nvm_queue_t *sq = &state->sq[pos], *cq = &state->cq[pos];
	nvm_dma_t *sq_mem = state->sq_mem[pos], *cq_mem = state->cq_mem[pos];
	void *cq_buf, *sq_buf;
	void *cq_db, *sq_db;
	struct local_admin *admin;
	uint16_t qid;
	int err;

	// create CQ
	err = cudaMalloc(&cq_buf, NVM_PAGE_ALIGN(qd*sizeof(nvm_cpl_t), 1 << 16)); //align to 64k
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}

	err = nvm_dma_map_device(&cq_mem, state->ctrlr, cq_buf, qd*sizeof(nvm_cpl_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		cudaFree(cq_buf);
		return err;
	}

	admin = (struct local_admin *)((uint8_t *)state->buf + state->ctrlr->page_size * 3);
	pthread_mutex_lock(&admin->mutex);
	qid = xnvme_array_find_first_and_set(admin->qids, admin->n_qps);
	if (!qid) {
		err = -ENOMEM;
		XNVME_DEBUG("FAILED: could not find free queue slot, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}
	state->used_qids[pos] = qid;

	err = nvm_admin_cq_create(state->aq, cq, qid, cq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O completion queue, err: %d", err);
		goto err;
	}

	err = cudaHostGetDevicePointer(&cq_db, (void *)cq->db, 0);
	if (err) {
		XNVME_DEBUG("FAILED: could not get device pointer, err: %d", err);
		goto err;
	}
	cq->db = (volatile uint32_t *) cq_db;

	err = cudaMalloc(&cq->head_mark, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		goto err;
	}
	err = cudaMalloc(&cq->pos_locks, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		goto err;
	}
	cq->qs_minus_1 = qd - 1;
	cq->qs_log2 = (uint32_t) XNVME_ILOG2(qd);

	// create SQ
	err = cudaMalloc(&sq_buf, NVM_PAGE_ALIGN(qd*sizeof(nvm_cmd_t), 1 << 16)); //align to 64k
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		goto err;
	}

	err = nvm_dma_map_device(&sq_mem, state->ctrlr, sq_buf, qd*sizeof(nvm_cmd_t));
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		cudaFree(sq_buf);
		goto err;
	}

	err = nvm_admin_sq_create(state->aq, sq, cq, qid, sq_mem, 0, qd, false);
	if (err) {
		XNVME_DEBUG("FAILED: could not create I/O submission queue, err: %d", err);
		cudaFree(sq_buf);
		goto err;
	}

	err = cudaHostGetDevicePointer(&sq_db, (void *)sq->db, 0);
	if (err) {
		XNVME_DEBUG("FAILED: could not get device pointer, err: %d", err);
		cudaFree(sq_buf);
		goto err;
	}
	sq->db = (volatile uint32_t *) sq_db;

	err = cudaMalloc(&sq->cid, (1<<16) * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		cudaFree(sq_buf);
		goto err;
	}
	err = cudaMalloc(&sq->tickets, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		cudaFree(sq_buf);
		goto err;
	}
	err = cudaMalloc(&sq->tail_mark, qd * sizeof(padded_struct));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		cudaFree(sq_buf);
		goto err;
	}
	sq->qs_minus_1 = qd - 1;
	sq->qs_log2 = (uint32_t) XNVME_ILOG2(qd);

	pthread_mutex_unlock(&admin->mutex);
	return 0;

err:
	pthread_mutex_unlock(&admin->mutex);
	return err;
}

int
xnvme_be_bam_gpu_create_queues(struct xnvme_dev *dev, uint16_t qd, uint16_t n_qps)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	int err;

	err = cudaMallocManaged(&state->sq, NVM_PAGE_ALIGN(sizeof(nvm_queue_t) * n_qps, 1 << 16));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory for SQ, err: %d", err);
		return err;
	}
	err = cudaMallocManaged(&state->cq, NVM_PAGE_ALIGN(sizeof(nvm_queue_t) * n_qps, 1 << 16));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory for CQ, err: %d", err);
		return err;
	}

	state->sq_mem = (nvm_dma_t **) calloc(n_qps, sizeof(nvm_dma_t *));
	if (!state->sq_mem) {
		err = errno;
		XNVME_DEBUG("FAILED: could not allocate memory for SQMEM, err: %d", err);
		return err;
	}

	state->cq_mem = (nvm_dma_t **) calloc(n_qps, sizeof(nvm_dma_t *));
	if (!state->cq_mem) {
		err = errno;
		XNVME_DEBUG("FAILED: could not allocate memory for CQMEM, err: %d", err);
		return err;
	}

	for (uint16_t i = 0; i < n_qps; i++) {
		err = xnvme_be_bam_gpu_queue_init(state, qd, i);
		if (err) {
			XNVME_DEBUG("FAILED: could not allocate QP: %d, err: %d", i, err);
			return err;
		}
	}

	state->n_qps = n_qps;
	return 0;
}

int
xnvme_be_bam_gpu_delete_queues(struct xnvme_dev *dev)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	int err;

	for (int i = 0; i < state->n_qps; i++) {
		err = xnvme_be_bam_gpu_queue_term(state, i);
		if (err) {
			XNVME_DEBUG("FAILED: could not terminate QP: %d, err: %d", i, err);
			return err;
		}
	}

	state->qid -= state->n_qps;
	state->n_qps = 0;

	cudaFree(state->sq);
	cudaFree(state->cq);
	free(state->sq_mem);
	free(state->cq_mem);
	return 0;
}

int
xnvme_be_bam_dev_open(struct xnvme_dev *dev)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	const struct xnvme_ident *ident = &dev->ident;
	nvm_dma_t *aq_mem;
	void *buf;
	int fd, devid, err;
	struct local_admin *admin;

	fd = open(ident->uri, O_RDWR);

	if (fd < 0) {
		XNVME_DEBUG("FAILED: open(uri: '%s'), fd: %d, errno: %d", ident->uri, fd, errno);
		return -errno;
	}

	err = nvm_ctrl_init(&state->ctrlr, fd);
	close(fd);
	if (err) {
		XNVME_DEBUG("FAILED: could not initialize controller from fd: %d, err: %d", fd, err);
		return err;
	}

	err = cudaHostRegister(state->ctrlr, sizeof(nvm_ctrl_t), cudaHostRegisterDefault);
	if (err) {
		XNVME_DEBUG("FAILED: could not map ctrlr memory, err: %d", err);
		return err;
	}

	err = cudaMallocManaged(&state->list, NVM_PAGE_ALIGN(sizeof(struct skiplist), 1 << 16));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory for skiplist, err: %d", err);
		return err;
	}
	skiplist_init(state->list);

	devid = ident->uri[strlen(ident->uri)-1] - '0';
	g_shmid_shared = shmget(SHM_KEY + devid, state->ctrlr->page_size * 3 + sizeof(struct local_admin), IPC_CREAT | 0666);
	if (g_shmid_shared < 0) {
		XNVME_DEBUG("FAILED: could not get shmid for shmd, err: %d", g_shmid_shared);
		return err;
	}

	XNVME_DEBUG("Got shared memory segment with shmid: %d", g_shmid_shared);
	buf = shmat(g_shmid_shared, NULL, 0);
	if (buf == NULL || buf == (void *) -1) {
		XNVME_DEBUG("FAILED: could not attach to shared memory segment, for shmid: %d", g_shmid_shared);
		return err;
	}
	XNVME_DEBUG("Attached to shared memory segment with shmid: %d, at %p", g_shmid_shared, buf);

	state->buf = buf;

	err = nvm_dma_map_host(&aq_mem, state->ctrlr, buf, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(buf);
		return err;
	}

	admin = (struct local_admin *)((uint8_t *)buf + state->ctrlr->page_size * 3);

	XNVME_DEBUG("page size: %u, admin: %p", state->ctrlr->page_size, admin);

	if (admin->qmem) {
		pthread_mutex_lock(&admin->mutex);
		err = nvm_aq_share(&state->aq, state->ctrlr, aq_mem, admin);
		pthread_mutex_unlock(&admin->mutex);
		state->primary = 0;
	} else {
		err = nvm_aq_create_new(&state->aq, state->ctrlr, aq_mem, admin);
		pthread_mutex_init(&admin->mutex, NULL);
		state->primary = 1;
		admin->n_qps = 32;
		for (int i = 0; i < 32; i++) {
			admin->qids[i] = 0;
		}

	}

	nvm_dma_unmap(aq_mem);
	if (err) {
		XNVME_DEBUG("FAILED: could not create/share admin queues, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}

	err = cudaHostRegister((void*) state->ctrlr->mm_ptr, NVM_CTRL_MEM_MINSIZE, cudaHostRegisterIoMemory);
	if (err) {
		XNVME_DEBUG("FAILED: could not map IO memory, err: %d", err);
		return err;
	}

	dev->ident.dtype = XNVME_DEV_TYPE_NVME_NAMESPACE;
	dev->ident.nsid = dev->opts.nsid;
	dev->ident.csi = XNVME_SPEC_CSI_NVM;

	err = xnvme_queue_init(dev, 4, 0, &state->sync_q);
	if (err) {
		XNVME_DEBUG("FAILED: could not setup sync queue");
		return err;
	}

	err = cudaStreamCreate(&state->stream);
	if (err) {
		XNVME_DEBUG("FAILED: could not create cuda stream, err: %d", err);
		return err;
	}

	err = cudaHostRegister(dev, sizeof(*dev), cudaHostRegisterDefault);
	if (err) {
		XNVME_DEBUG("FAILED: could not map dev memory, err: %d", err);
		return err;
	}

	return 0;
}

void
xnvme_be_bam_dev_close(struct xnvme_dev *dev)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;

	xnvme_queue_term(state->sync_q);
	skiplist_term(state->list, xnvme_be_bam_cpu_dma_unmap);
	nvm_aq_destroy(state->aq);
	cudaHostUnregister((void *)state->ctrlr->mm_ptr);
	cudaHostUnregister(state->ctrlr);
	cudaStreamDestroy(state->stream);

	if (shmdt(state->buf) < 0) {
		XNVME_DEBUG("FAILED: could not detach the shared memory segment, for shmid: %d",
			     g_shmid_shared);
	}

	if (state->primary && shmctl(g_shmid_shared, IPC_RMID, NULL)) {
		XNVME_DEBUG("FAILED: could not remove the shared memory segment, for shmid: %d",
			    g_shmid_shared);
	}

	nvm_ctrl_free(state->ctrlr);
	cudaHostUnregister(dev);
}

#endif

struct xnvme_be_dev g_xnvme_be_bam_dev = {
#ifdef XNVME_BE_BAM_ENABLED
	.enumerate = xnvme_be_nosys_enumerate,
	.dev_open = xnvme_be_bam_dev_open,
	.dev_close = xnvme_be_bam_dev_close,
#else
	.enumerate = xnvme_be_nosys_enumerate,
	.dev_open = xnvme_be_nosys_dev_open,
	.dev_close = xnvme_be_nosys_dev_close,
#endif
};
