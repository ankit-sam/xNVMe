#include <xnvme_cmd.h>
#include <xnvme_dev.h>
#include <xnvme_be_bam.h>

__global__ void
_cmd_submit(struct xnvme_dev *dev, uint32_t opc, uint32_t slba, uint32_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf, uint32_t n_threads)
{
	uint64_t i = 0;
	while(true) {
		struct xnvme_cmd_ctx ctx = {.dev = dev, .opts = XNVME_CMD_SYNC};
		uint64_t tid = blockIdx.x * blockDim.x + threadIdx.x + i*n_threads;
		uint32_t cur_slba = slba + tid * (nlb + 1);

		if (cur_slba + nlb > elba) { // continue until reaching elba
			return;
		}
		ctx.cmd.common.nsid = dev->ident.nsid;
		ctx.cmd.common.opcode = opc;
		ctx.cmd.nvm.nlb = nlb;
		ctx.cmd.nvm.slba = cur_slba;

		void *buf = (char *) dbuf + (cur_slba - slba) * dev->geo.lba_nbytes;

		xnvme_be_bam_sync_cmd_io(&ctx, buf, nbytes, NULL, 0);
		i++;
	}
}

int
xnvme_kernels_cmd_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev, uint32_t opc, uint32_t slba, uint32_t elba, uint32_t nlb, uint64_t nbytes, void *dbuf)
{
	cudaError_t err;
	_cmd_submit<<<grid_size, tblock_size>>>(dev, opc, slba, elba, nlb, nbytes, dbuf, grid_size * tblock_size);
	err = cudaGetLastError();
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error launching kernel: %s", cudaGetErrorString(err));
		return err;
	}
	err = cudaDeviceSynchronize();
	if (err != cudaSuccess) {
		XNVME_DEBUG("Error synchronizing: %s", cudaGetErrorString(err));
		return err;
	}

	return 0;
 }

