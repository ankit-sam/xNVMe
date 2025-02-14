// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

extern "C" {
#include <xnvme_be.h>
#include <xnvme_be_nosys.h>
}
#ifdef XNVME_BE_BAM_ENABLED
#include <errno.h>
#include <xnvme_be_bam.h>
#include <xnvme_dev.h>


__device__ __host__ static int
_cmp(const void *vaddr, const struct skiplist_node *n)
{
	struct xnvme_be_bam_memory *m = container_of(n, struct xnvme_be_bam_memory, list);
	uint64_t a = (uint64_t) vaddr;
	uint64_t b = (uint64_t) m->mem->vaddr;

	if (a < b)
		return -1;
	else if (a >= b + m->mem->n_ioaddrs*m->mem->page_size)
		return 1;

	return 0;
}

__device__ __host__ struct xnvme_be_bam_memory *
xnvme_be_bam_memory_find(struct xnvme_be_bam_state *state, void *buf)
{
	return container_of_or_null(skiplist_find(state->list, buf, _cmp, NULL), struct xnvme_be_bam_memory, list);
}

void *
xnvme_be_bam_buf_alloc(const struct xnvme_dev *dev, size_t nbytes, uint64_t *XNVME_UNUSED(phys))
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	struct skiplist_node *update[SKIPLIST_LEVELS] = {};
	struct xnvme_be_bam_memory *m;
	void *buf;
	nvm_dma_t *mem;
	int err;

	err = cudaMalloc(&buf, NVM_PAGE_ALIGN(nbytes, 1 << 16)); //align to 64K;
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		return NULL;
	}

	err = nvm_dma_map_device(&mem, state->ctrlr, buf, nbytes);
	if (err) {
		XNVME_DEBUG("FAILED: could not dma map memory, err: %d", err);
		cudaFree(buf);
		return NULL;
	}

	if (skiplist_find(state->list, mem->vaddr, _cmp, update)) {
		XNVME_DEBUG("FAILED: mem->vaddr already exist in the skiplist");
		goto error;
	}

	err = cudaHostRegister(mem, sizeof(nvm_dma_t), cudaHostRegisterDefault);
	if (err) {
		XNVME_DEBUG("FAILED: could not map dev memory, err: %d", err);
		goto error;
	}

	err = cudaHostRegister(mem->ioaddrs, sizeof(uint64_t) * mem->n_ioaddrs, cudaHostRegisterDefault);
	if (err) {
		XNVME_DEBUG("FAILED: could not map dev memory, err: %d", err);
		goto error;
	}

	err = cudaMallocManaged(&m, NVM_PAGE_ALIGN(sizeof(struct xnvme_be_bam_memory), 1 << 16));
	if (err) {
		XNVME_DEBUG("FAILED: could not allocate memory, err: %d", err);
		goto error;
	}

	m->mem = mem;

	skiplist_link(state->list, &m->list, update);
	return mem->vaddr;

error:
	nvm_dma_unmap(mem);
	return NULL;
}

void
xnvme_be_bam_buf_free(const struct xnvme_dev *dev, void *buf)
{
	struct xnvme_be_bam_state *state = (struct xnvme_be_bam_state *)dev->be.state;
	struct skiplist_node *update[SKIPLIST_LEVELS] = {};
	struct xnvme_be_bam_memory *m;

	m = container_of_or_null(skiplist_find(state->list, buf, _cmp, update), struct xnvme_be_bam_memory, list);
	if (!m) {
		XNVME_DEBUG("FAILED: couldn't find memory in skiplist");
		return;
	}

	skiplist_erase(state->list, &m->list, update);
	cudaHostUnregister(m->mem->ioaddrs);
	cudaHostUnregister(m->mem);
	nvm_dma_unmap(m->mem);
	cudaFree(m);
}

#endif

struct xnvme_be_mem g_xnvme_be_bam_mem = {
#ifdef XNVME_BE_BAM_ENABLED
	.buf_alloc = xnvme_be_bam_buf_alloc,
	.buf_vtophys = xnvme_be_nosys_buf_vtophys,
	.buf_realloc = xnvme_be_nosys_buf_realloc,
	.buf_free = xnvme_be_bam_buf_free,
	.mem_map = xnvme_be_nosys_mem_map,
	.mem_unmap = xnvme_be_nosys_mem_unmap,
#else
	.buf_alloc = xnvme_be_nosys_buf_alloc,
	.buf_vtophys = xnvme_be_nosys_buf_vtophys,
	.buf_realloc = xnvme_be_nosys_buf_realloc,
	.buf_free = xnvme_be_nosys_buf_free,
	.mem_map = xnvme_be_nosys_mem_map,
	.mem_unmap = xnvme_be_nosys_mem_unmap,
#endif
	.id = "bam",
};
