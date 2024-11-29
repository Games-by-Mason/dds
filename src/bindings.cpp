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
		float * const pixels
	) {
		// Encode the image as u8s. We need to do this before initializing the encoder, since doing
		// so may change the perceptual param that we reference here.
		utils::image_u8 img;
		img.init(width, height);
		auto u8s = img.get_pixels();
		for (size_t i = 0; i < (size_t)width * (size_t)height * 4; ++i) {
			float ldr = pixels[i];
			if (params->m_perceptual && i % 4 != 3) ldr = pow(ldr, 1.0f / 2.2f);
			ldr = ldr * 255.0f + 0.5f;
			if (ldr < 0.0f) {
				ldr = 0.0f;
			} else if (ldr > 255.0f) {
				ldr = 255.0f;
			}
			u8s[i] = (uint8_t)ldr;
		}

		// Encode the data as BC7. This may modify params which is referenced above.
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
