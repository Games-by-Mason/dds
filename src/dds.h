#include <stdint.h>
#include <stdbool.h>
	
void * bc7enc_init();
void bc7enc_deinit(void * encoder);
bool bc7enc_encode(
	void * encoder,
	void * const options,
	uint32_t width,
	uint32_t height,
	uint8_t * const pixels
);
uint8_t * bc7enc_get_blocks(void * encoder);
uint32_t bc7enc_get_total_blocks_size_in_bytes(void * encoder);