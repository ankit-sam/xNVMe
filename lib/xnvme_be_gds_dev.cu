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
#include <xnvme_be_gds.h>

int g_shmid = -1;

int
xnvme_be_gds_dev_open(struct xnvme_dev *dev)
{
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state *)dev->be.state;
	const struct xnvme_ident *ident = &dev->ident;
	nvm_dma_t *aq_mem;
	void *buf;
	int fd, err;
	cudaError_t cudaErr;
	struct local_admin *admin;
	uint16_t n_qps;
	uint16_t n_sqs = XNVME_BE_GDS_NQUEUES_MAX, n_cqs = XNVME_BE_GDS_NQUEUES_MAX;

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

	state->list = (struct skiplist *) malloc(sizeof(struct skiplist));
	if (!state->list) {
		XNVME_DEBUG("FAILED: could not allocate memory for skiplist");
		return -ENOMEM;
	}
	skiplist_init(state->list);

#if 0
	err = posix_memalign(&buf, 4096, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return err;
	}
#endif
	g_shmid = shmget(SHM_KEY, state->ctrlr->page_size * 3 + sizeof(struct local_admin), IPC_CREAT | IPC_EXCL | 0666);
	if (g_shmid < 0) {
		XNVME_DEBUG("FAILED: could not create shared memory segment, err: %d", g_shmid);
		return err;
	}

	XNVME_DEBUG("Created shared memory segment with shmid: %d", g_shmid);
	buf = shmat(g_shmid, NULL, 0);
	if (buf == NULL || buf == (void *) -1) {
		XNVME_DEBUG("FAILED: could not attach to shared memory segment, for shmid: %d", g_shmid);
		free(buf);
		return err;
	}
	XNVME_DEBUG("Attached to shared memory segment with shmid: %d, at %p", g_shmid, buf);

	state->buf = buf;

	err = nvm_dma_map_host(&aq_mem, state->ctrlr, buf, state->ctrlr->page_size * 3);
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		free(buf);
		return err;
	}

	admin = (struct local_admin *)((uint8_t *)buf + state->ctrlr->page_size * 3);

	pthread_mutex_init(&admin->mutex, NULL);

	pthread_mutex_lock(&admin->mutex);

	XNVME_DEBUG("page size: %u, admin: %p", state->ctrlr->page_size, admin);
	err = nvm_aq_create_new(&state->aq, state->ctrlr, aq_mem, admin);
	nvm_dma_unmap(aq_mem);
	if (err) {
		XNVME_DEBUG("FAILED: could not create admin queues, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}
	// QID 0 is the ADMIN queue, 1 to 15 is for BAM application
	state->qid = 16;
	state->qloc = 0;

	cudaErr = cudaHostRegister((void*) state->ctrlr->mm_ptr, NVM_CTRL_MEM_MINSIZE, cudaHostRegisterIoMemory);
	if (err != cudaSuccess) {
		XNVME_DEBUG("FAILED: could not map IO memory, err: %s", cudaGetErrorString(cudaErr));
		pthread_mutex_unlock(&admin->mutex);
		return cudaErr;
	}

	err = nvm_admin_request_num_queues(state->aq, &n_sqs, &n_cqs);
	if (err) {
		XNVME_DEBUG("FAILED: could not reserve I/O queues, err: %d", err);
		pthread_mutex_unlock(&admin->mutex);
		return err;
	}

	n_qps = XNVME_MIN(n_sqs, n_cqs);
	state->sq = (nvm_queue_t *) malloc(sizeof(nvm_queue_t) * n_qps);
	if (!state->sq) {
			XNVME_DEBUG("FAILED: could not allocate memory for SQ");
			pthread_mutex_unlock(&admin->mutex);
			return -ENOMEM;
	}

	state->cq = (nvm_queue_t *) malloc(sizeof(nvm_queue_t) * n_qps);
	if (!state->cq) {
			XNVME_DEBUG("FAILED: could not allocate memory for CQ");
			pthread_mutex_unlock(&admin->mutex);
			return -ENOMEM;
	}

	dev->ident.dtype = XNVME_DEV_TYPE_NVME_NAMESPACE;
	dev->ident.nsid = dev->opts.nsid;
	dev->ident.csi = XNVME_SPEC_CSI_NVM;

	pthread_mutex_unlock(&admin->mutex);

	return 0;
}

void
xnvme_be_gds_dev_close(struct xnvme_dev *dev)
{
	struct xnvme_be_gds_state *state = (struct xnvme_be_gds_state *)dev->be.state;

	free(state->sq);
	free(state->cq);
	nvm_aq_destroy(state->aq);
	cudaHostUnregister((void *)state->ctrlr->mm_ptr);

	if (shmdt(state->buf) < 0) {
		XNVME_DEBUG("FAILED: could not detach the shared memory segment, for shmid: %d", g_shmid);
	}

	if (shmctl(g_shmid, IPC_RMID, NULL)) {
		XNVME_DEBUG("FAILED: could not remove the shared memory segment, for shmid: %d", g_shmid);
	}

	nvm_ctrl_free(state->ctrlr);
}

#endif

struct xnvme_be_dev g_xnvme_be_gds_dev = {
#ifdef XNVME_BE_BAM_ENABLED
	.enumerate = xnvme_be_nosys_enumerate,
	.dev_open = xnvme_be_gds_dev_open,
	.dev_close = xnvme_be_gds_dev_close,
#else
	.enumerate = xnvme_be_nosys_enumerate,
	.dev_open = xnvme_be_nosys_dev_open,
	.dev_close = xnvme_be_nosys_dev_close,
#endif
};
