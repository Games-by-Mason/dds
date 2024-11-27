#include <stdio.h>
#include <bc7enc/rdo_bc_encoder.h>
#include <bc7enc/utils.h>

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STBIR_SSE2
#define STBIR_AVX
#define STBIR_AVX2
#define STBIR_USE_FMA
#include "stb_image_resize2.h"

extern "C" {
	rdo_bc::rdo_bc_encoder * bc7enc_init() {
		return new rdo_bc::rdo_bc_encoder();
	}

	void bc7enc_deinit(rdo_bc::rdo_bc_encoder * encoder) {
		delete encoder;
	}

	bool bc7enc_encode(
		rdo_bc::rdo_bc_encoder * encoder,
		rdo_bc::rdo_bc_params * const params,
		uint32_t width,
		uint32_t height,
		uint8_t * const pixels
	) {
		utils::image_u8 img;
		img.init(width, height);
		memcpy(&img.get_pixels()[0], &pixels[0], width * height * sizeof(uint32_t));

		if (!encoder->init(img, *params)) {
			return false;
		}

		if (!encoder->encode()) return false;

		return true;
	}

	uint8_t * bc7enc_getBlocks(rdo_bc::rdo_bc_encoder * encoder) {
		return (uint8_t *)encoder->get_blocks();
	}

	uint32_t bc7enc_getTotalBlocksSizeInBytes(rdo_bc::rdo_bc_encoder * encoder) {
		return encoder->get_total_blocks_size_in_bytes();
	}
}
