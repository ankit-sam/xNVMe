/**
 * SPDX-FileCopyrightText: Samsung Electronics Co., Ltd
 *
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * @headerfile libxnvme_kernels.h
 */

int
xnvme_kernels_cmd_submit(uint32_t grid_size, uint32_t tblock_size, struct xnvme_dev *dev,
			 uint32_t opc, uint32_t slba, uint32_t elba, uint32_t nlb, uint64_t nbytes,
			 void *dbuf);
