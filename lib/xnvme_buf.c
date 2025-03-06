// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

#include <stdint.h>
#include <limits.h>
#include <errno.h>
#include <libxnvme.h>
#include <xnvme_dev.h>
#include <xnvme_be.h>
#include <cuda_runtime.h>

void *
xnvme_buf_virt_alloc(size_t alignment, size_t nbytes)
{
	if (!nbytes) {
		errno = EINVAL;
		XNVME_DEBUG("FAILED: invalid value for nbytes: '%zu')", nbytes);
		return NULL;
	}
	// nbytes has to be a multiple of alignment. Therefore, we round up to the nearest
	// multiple.
	nbytes = (1 + ((nbytes - 1) / alignment)) * (alignment);
#ifdef WIN32
	return _aligned_malloc(nbytes, alignment);
#else
	return aligned_alloc(alignment, nbytes);
#endif
}

void *
xnvme_buf_virt_realloc(void *XNVME_UNUSED(buf), size_t XNVME_UNUSED(alignment),
		       size_t XNVME_UNUSED(nbytes))
{
	errno = ENOSYS;
	return NULL;
}

void
xnvme_buf_virt_free(void *buf)
{
#ifdef WIN32
	_aligned_free(buf);
#else
	free(buf);
#endif
}

void *
xnvme_buf_phys_alloc(const struct xnvme_dev *dev, size_t nbytes, uint64_t *phys)
{
	return dev->be.mem.buf_alloc(dev, nbytes, phys);
}

void *
xnvme_buf_phys_realloc(const struct xnvme_dev *dev, void *buf, size_t nbytes, uint64_t *phys)
{
	return dev->be.mem.buf_realloc(dev, buf, nbytes, phys);
}

void
xnvme_buf_phys_free(const struct xnvme_dev *dev, void *buf)
{
	dev->be.mem.buf_free(dev, buf);
}

int
xnvme_buf_vtophys(const struct xnvme_dev *dev, void *buf, uint64_t *phys)
{
	return dev->be.mem.buf_vtophys(dev, buf, phys);
}

void *
xnvme_buf_alloc(const struct xnvme_dev *dev, size_t nbytes)
{
	return dev->be.mem.buf_alloc(dev, nbytes, NULL);
}

void *
xnvme_buf_realloc(const struct xnvme_dev *dev, void *buf, size_t nbytes)
{
	return dev->be.mem.buf_realloc(dev, buf, nbytes, NULL);
}

void
xnvme_buf_free(const struct xnvme_dev *dev, void *buf)
{
	xnvme_buf_phys_free(dev, buf);
}

void *
xnvme_buf_clear(void *buf, size_t nbytes)
{
	struct cudaPointerAttributes attr;
	cudaError_t err;

	err = cudaPointerGetAttributes(&attr, buf);
	if (err != cudaSuccess) {
		XNVME_DEBUG("FAILED: cudaPointerGetAttributes, err: %s", cudaGetErrorString(err))
		return NULL;
	}
	if (attr.type == cudaMemoryTypeDevice) {
		err = cudaMemset(buf, 0, sizeof(nbytes));
		if (err != cudaSuccess) {
			XNVME_DEBUG("FAILED: cudaMemset, err: %s", cudaGetErrorString(err))
			return NULL;
		}
		return buf;
	}

	return memset(buf, 0, nbytes);
}

void *
xnvme_buf_copy(void *dst, void *src, size_t nbytes)
{
	struct cudaPointerAttributes src_attr;
	struct cudaPointerAttributes dst_attr;
	enum cudaMemcpyKind kind;
	cudaError_t err;

	err = cudaPointerGetAttributes(&src_attr, src);
	if (err != cudaSuccess) {
		XNVME_DEBUG("FAILED: cudaPointerGetAttributes, err: %s", cudaGetErrorString(err))
		return NULL;
	}

	err = cudaPointerGetAttributes(&dst_attr, dst);
	if (err != cudaSuccess) {
		XNVME_DEBUG("FAILED: cudaPointerGetAttributes, err: %s", cudaGetErrorString(err))
		return NULL;
	}

	if (src_attr.type == cudaMemoryTypeDevice) {
		switch (dst_attr.type) {
		case cudaMemoryTypeDevice:
			kind = cudaMemcpyDeviceToDevice;
			break;
		default:
			kind = cudaMemcpyDeviceToHost;
			break;
		}
	} else {
		switch (dst_attr.type) {
		case cudaMemoryTypeDevice:
			kind = cudaMemcpyHostToDevice;
			break;
		default:
			kind = cudaMemcpyHostToHost;
			break;
		}
	}

	err = cudaMemcpy(dst, src, nbytes, kind);
	if (err != cudaSuccess) {
		XNVME_DEBUG("FAILED: cudaMemcpy, err: %s", cudaGetErrorString(err))
		return NULL;
	}
	return dst;
}
/**
 * Helper function writing/reading given buf to/from file. When mode has
 * O_WRONLY, the given buffer is written to file, otherwise, it is read.
 *
 * NOTE: this depends on POSIX syscalls
 */
static int
fdio_func(void *buf, size_t nbytes, const char *path, struct xnvme_opts *opts)
{
	struct xnvme_cmd_ctx ctx = {0};
	struct xnvme_dev *fh = NULL;
	size_t transferred = 0;
	int err = 0;

	fh = xnvme_file_open(path, opts);
	if (fh == NULL) {
		XNVME_DEBUG("FAILED: xnvme_file_open(), errno: %d", errno);
		return -errno;
	}

	ctx = xnvme_file_get_cmd_ctx(fh);

	while (transferred < nbytes) {
		const size_t remain = nbytes - transferred;
		size_t nbytes_call = remain < SSIZE_MAX ? remain : SSIZE_MAX;

		if (opts->wronly) {
			err = xnvme_file_pwrite(&ctx, buf + transferred, nbytes_call, transferred);
		} else {
			err = xnvme_file_pread(&ctx, buf + transferred, nbytes_call, transferred);
		}
		if (err) {
			XNVME_DEBUG("FAILED: opts->wronly: %d, cpl.result: %ld, errno: %d",
				    opts->wronly, ctx.cpl.result, errno);
			xnvme_file_close(fh);
			return -errno;
		}

		// when reading, break at end of file
		if (!opts->wronly && ctx.cpl.result == 0) {
			break;
		}

		transferred += ctx.cpl.result;
	}

	err = xnvme_file_close(fh);
	if (err) {
		XNVME_DEBUG("FAILED: opts->wronly: %d, err: %d, errno: %d", opts->wronly, err,
			    errno);
		return -errno;
	}

	return 0;
}

int
xnvme_buf_from_file(void *buf, size_t nbytes, const char *path)
{
	struct xnvme_opts opts = {
		.rdonly = 1,
	};

	return fdio_func(buf, nbytes, path, &opts);
}

int
xnvme_buf_to_file(void *buf, size_t nbytes, const char *path)
{
	struct xnvme_opts opts = {
		.create = 1,
		.wronly = 1,
		.create_mode = S_IWUSR | S_IRUSR,
	};

	return fdio_func(buf, nbytes, path, &opts);
}

int
xnvme_buf_fill(void *buf, size_t nbytes, const char *content)
{
	struct cudaPointerAttributes attr;
	cudaError_t cudaErr;
	uint8_t *cbuf;

	cudaErr = cudaPointerGetAttributes(&attr, buf);
	if (cudaErr != cudaSuccess) {
		XNVME_DEBUG("FAILED: cudaPointerGetAttributes, err: %s",
			    cudaGetErrorString(cudaErr))
		return -cudaErr;
	}

	if (attr.type == cudaMemoryTypeDevice) {
		cbuf = malloc(nbytes);
	} else {
		cbuf = buf;
	}

	if (!strncmp(content, "anum", 4)) {
		for (size_t i = 0; i < nbytes; ++i) {
			cbuf[i] = (i % 26) + 65;
		}

		goto memcpy;
	}

	if (!strncmp(content, "rand-t", 6)) {
		srand(time(NULL));
		for (size_t i = 0; i < nbytes; ++i) {
			cbuf[i] = (rand() % 26) + 65;
		}

		goto memcpy;
	}

	if (!strncmp(content, "rand-k", 6)) {
		srand(0);
		for (size_t i = 0; i < nbytes; ++i) {
			cbuf[i] = (rand() % 26) + 65;
		}

		goto memcpy;
	}

	if (!strncmp(content, "ascii", 5)) {
		for (size_t i = 0; i < nbytes; ++i) {
			cbuf[i] = (i % 26) + 65;
		}

		goto memcpy;
	}

	if (!strncmp(content, "zero", 4)) {
		memset(cbuf, 0, nbytes);
		goto memcpy;
	}

	if (attr.type == cudaMemoryTypeDevice) {
		free(cbuf);
	}

	return xnvme_buf_from_file(buf, nbytes, content);

memcpy:
	if (attr.type == cudaMemoryTypeDevice) {
		cudaErr = cudaMemcpy(buf, cbuf, nbytes, cudaMemcpyHostToDevice);
		if (cudaErr != cudaSuccess) {
			XNVME_DEBUG("FAILED: cudaMemcpy, err: %s", cudaGetErrorString(cudaErr))
			return cudaErr;
		}
		free(cbuf);
	}

	return 0;
}

size_t
xnvme_buf_diff(const void *expected, const void *actual, size_t nbytes)
{
	struct cudaPointerAttributes exp_attr;
	struct cudaPointerAttributes act_attr;
	const uint8_t *exp;
	const uint8_t *act;
	cudaError_t cudaErr;
	size_t diff = 0;

	cudaErr = cudaPointerGetAttributes(&exp_attr, expected);
	if (cudaErr != cudaSuccess) {
		XNVME_DEBUG("FAILED: cudaPointerGetAttributes, err: %s",
			    cudaGetErrorString(cudaErr))
		return -cudaErr;
	}

	cudaErr = cudaPointerGetAttributes(&act_attr, expected);
	if (cudaErr != cudaSuccess) {
		XNVME_DEBUG("FAILED: cudaPointerGetAttributes, err: %s",
			    cudaGetErrorString(cudaErr))
		return -cudaErr;
	}
	if (exp_attr.type != act_attr.type) {
		XNVME_DEBUG("FAILED: memory type for expected and actual doesn't match");
		return -EINVAL;
	}

	if (exp_attr.type == cudaMemoryTypeDevice) {
		exp = malloc(nbytes);
		act = malloc(nbytes);
		cudaErr = cudaMemcpy((void *)exp, expected, nbytes, cudaMemcpyDeviceToHost);
		if (cudaErr != cudaSuccess) {
			XNVME_DEBUG("FAILED: cudaMemcpy, err: %s", cudaGetErrorString(cudaErr))
			return -cudaErr;
		}

		cudaErr = cudaMemcpy((void *)act, actual, nbytes, cudaMemcpyDeviceToHost);
		if (cudaErr != cudaSuccess) {
			XNVME_DEBUG("FAILED: cudaMemcpy, err: %s", cudaGetErrorString(cudaErr))
			return -cudaErr;
		}
	} else {
		exp = expected;
		act = actual;
	}

	for (size_t i = 0; i < nbytes; ++i) {
		if (exp[i] == act[i]) {
			continue;
		}

		++diff;
	}

	if (exp_attr.type == cudaMemoryTypeDevice) {
		free((void *)exp);
		free((void *)act);
	}

	return diff;
}

void
xnvme_buf_diff_pr(const void *expected, const void *actual, size_t nbytes, int XNVME_UNUSED(opts))
{
	const uint8_t *exp = expected;
	const uint8_t *act = actual;
	size_t diff = 0;

	printf("comparison:\n");
	printf("  diffs:\n");
	for (size_t i = 0; i < nbytes; ++i) {
		if (exp[i] == act[i]) {
			continue;
		}

		++diff;
		printf("    - {byte: '%06zu', expected: 0x%" PRIx8 ", actual: 0x%" PRIx8 ")\n", i,
		       exp[i], act[i]);
	}
	printf("  nbytes: %zu\n", nbytes);
	printf("  nbytes_diff: %zu\n", diff);
}

int
xnvme_mem_map(const struct xnvme_dev *dev, void *vaddr, size_t nbytes)
{
	return dev->be.mem.mem_map(dev, vaddr, nbytes, NULL);
}

int
xnvme_mem_unmap(const struct xnvme_dev *dev, void *buf)
{
	return dev->be.mem.mem_unmap(dev, buf);
}
