// SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
//
// SPDX-License-Identifier: BSD-3-Clause

#include <errno.h>
#include <libxnvme.h>

struct iowork_range {
	uint32_t slba;   ///< First LBA of the range
	uint32_t elba;   ///< Last LBA of the range
	uint64_t nbytes; ///< Number of bytes in range
	uint64_t naddr;  ///< Number of addresses (count-from-1)
	uint64_t nlb;    ///< Number of LBAs (count-from-0)
};

/**
 * Argument setup for I/O work
 */
struct iowork {
	const struct xnvme_geo *geo;
	struct xnvme_dev *dev;
	struct xnvme_queue *queue;
	uint32_t nsid;
	uint32_t opc;

	struct iowork_range range; ///< Range to confine I/O inside of

	struct {
		size_t nlb;    ///< Number of LBAs per I/O (count-from-0)
		size_t nbytes; ///< Number of bytes pr. I/O
		size_t naddr;  ///< Number of addresses per I/O (count-from-1)
	} io;                  ///< Per I/O args

	char *wbuf;
	char *rbuf;

	struct {
		char *data;
		uint64_t slba;
	} cur;

	uint64_t nio; ///< Number of I/Os to complete (count-from-1)
};

int
iowork_pp(struct iowork *work)
{
	int wrtn = 0;

	wrtn += printf("iowork:");
	if (!work) {
		wrtn += printf(" ~\n");
		return wrtn;
	}

	printf("\n");
	printf("  io.nbytes: %zu\n", work->io.nbytes);
	printf("  io.naddr: %zu\n", work->io.naddr);
	printf("  range.nbytes: %" PRIu64 "\n", work->range.nbytes);
	printf("  range.naddr: %" PRIu64 "\n", work->range.naddr);
	printf("  range.slba: %" PRIu32 "\n", work->range.slba);
	printf("  range.elba: %" PRIu32 "\n", work->range.elba);
	printf("  nio: %" PRIu64 "\n", work->nio);

	return 0;
}


/**
 * Tear down function for I/O worker arguments
 */
static int
iowork_teardown(struct iowork *work)
{
	xnvme_buf_free(work->dev, work->rbuf);
	xnvme_buf_free(work->dev, work->wbuf);

	return 0;
}

static int
iowork_from_cli(struct xnvme_cli *cli, struct iowork *work)
{
	int err;

	cudaMemset(work, 0, sizeof(struct iowork));

	work->dev = cli->args.dev;
	work->nsid = xnvme_dev_get_nsid(work->dev);
	work->geo = xnvme_dev_get_geo(work->dev);

	work->io.nlb = cli->given[XNVME_CLI_OPT_NLB] ? cli->args.nlb : 0;
	work->io.naddr = work->io.nlb + 1;
	work->io.nbytes = work->io.naddr * work->geo->lba_nbytes;

	work->range.nbytes = 1 << 24;
	work->range.naddr = work->range.nbytes / work->geo->lba_nbytes;
	work->range.slba = 0;
	work->range.elba = work->range.slba + work->range.naddr - 1;

	work->nio = work->range.naddr / work->io.naddr;

	work->wbuf = (char *) xnvme_buf_alloc(cli->args.dev, work->range.nbytes);
	if (!work->wbuf) {
		err = -errno;
		XNVME_DEBUG("FAILED: xnvme_buf_alloc(wbuf), err: %d", errno);
		goto failed;
	}
	xnvme_buf_fill(work->wbuf, work->range.nbytes, "rand-t");

	work->rbuf = (char *) xnvme_buf_alloc(cli->args.dev, work->range.nbytes);
	if (!work->rbuf) {
		err = -errno;
		XNVME_DEBUG("FAILED: xnvme_buf_alloc(rbuf), err: %d", errno);
		goto failed;
	}
	xnvme_buf_fill(work->rbuf, work->range.nbytes, "zero");
	return 0;

failed:
	iowork_teardown(work);
	return err;
}

static int
final(struct iowork work)
{
	size_t diff;

	diff = xnvme_buf_diff(work.wbuf, work.rbuf, work.range.nbytes);
	iowork_teardown(&work);

	if (diff) {
		xnvme_cli_pinf("ERR: {diff: %" PRIu64 "}", diff);
		return EIO;
	}
	xnvme_cli_pinf("SUCCESS!");
	return 0;
}

static int
test_verify(struct xnvme_cli *cli)
{
	struct iowork *work;
	int err, x, y;

	cudaMallocManaged(&work, sizeof(struct iowork));
	err = iowork_from_cli(cli, work);
	if (err) {
		XNVME_DEBUG("FAILED: iowork_from_cli(), err: %d", err);
		return err;
	}

	iowork_pp(work);
	xnvme_dev_pr(work->dev, XNVME_PR_DEF);

	for (int i = 0; i < 2; i++) {

		work->cur.data = i ? work->rbuf : work->wbuf;
		work->opc = i ? XNVME_SPEC_NVM_OPC_READ : XNVME_SPEC_NVM_OPC_WRITE;


		y = 64;
		x = (work->nio + y - 1)/y;

		err = xnvme_kernels_cmd_submit(x, y, work->dev, work->opc, work->range.slba, work->range.elba, work->io.nlb, work->io.nbytes, work->cur.data);
		if (err) {
			return err;
		}
	}

	return final(*work);
}

static struct xnvme_cli_sub g_subs[] = {
	{
		"verify",
		"Write, then read and compare",
		"Write, then read and compare",
		test_verify,
		{
			{XNVME_CLI_OPT_POSA_TITLE, XNVME_CLI_SKIP},
			{XNVME_CLI_OPT_URI, XNVME_CLI_POSA},

			{XNVME_CLI_OPT_NON_POSA_TITLE, XNVME_CLI_SKIP},
			{XNVME_CLI_OPT_NLB, XNVME_CLI_LOPT},
			XNVME_CLI_SYNC_OPTS,
		},
	},
};

static struct xnvme_cli g_cli = {
	.title = "Test xNVMe basic buffer alloc/free",
	.descr_short = "Test xNVMe basic buffer alloc/free",
	.nsubs = sizeof g_subs / sizeof(*g_subs),
	.subs = g_subs,
};

int
main(int argc, char **argv)
{
	return xnvme_cli_run(&g_cli, argc, argv, XNVME_CLI_INIT_DEV_OPEN);
}
