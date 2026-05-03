#include "neopixel.h"
#include "pico/stdlib.h"
#include "hardware/pio.h"
#include "hardware/dma.h"
#include "hardware/clocks.h"
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <iterator>

namespace {

const uint16_t ws2812_instructions[] = {
    0x6321, // out x, 1        side 0 [3]
    0x1223, // jmp !x, 3       side 1 [2]
    0x1200, // jmp 0           side 1 [2]
    0xa242, // nop              side 0 [2]
};

const struct pio_program ws2812_prog = {
    .instructions = ws2812_instructions,
    .length = 4,
    .origin = -1,
};

static PIO  neo_pio = pio1;
static uint neo_sm;
static int  neo_dma;
static uint32_t led_data[neopixel::Count];

uint32_t encode_urgbw(uint8_t r, uint8_t g, uint8_t b, uint8_t w) {
    if constexpr (neopixel::IsRgbw) {
        return (static_cast<uint32_t>(r) << 24) | (static_cast<uint32_t>(g) << 16) | 
               (static_cast<uint32_t>(b) << 8) | w;
    } else {
        return (static_cast<uint32_t>(g) << 24) | (static_cast<uint32_t>(r) << 16) | 
               (static_cast<uint32_t>(b) << 8);
    }
}

} // namespace

extern "C" {

void neopixel_init() {
    uint offset = pio_add_program(neo_pio, &ws2812_prog);
    neo_sm = pio_claim_unused_sm(neo_pio, true);
    pio_sm_config cfg = pio_get_default_sm_config();
    sm_config_set_wrap(&cfg, offset, offset + 3);
    sm_config_set_sideset(&cfg, 1, false, false);
    sm_config_set_sideset_pins(&cfg, neopixel::Pin);
    pio_gpio_init(neo_pio, neopixel::Pin);
    pio_sm_set_consecutive_pindirs(neo_pio, neo_sm, neopixel::Pin, 1, true);
    float div = static_cast<float>(clock_get_hz(clk_sys)) / (800000.0f * 10.0f);
    sm_config_set_clkdiv(&cfg, div);
    sm_config_set_out_shift(&cfg, false, true, neopixel::IsRgbw ? 32 : 24);
    sm_config_set_fifo_join(&cfg, PIO_FIFO_JOIN_TX);
    pio_sm_init(neo_pio, neo_sm, offset, &cfg);
    pio_sm_set_enabled(neo_pio, neo_sm, true);

    neo_dma = dma_claim_unused_channel(true);
    dma_channel_config dcfg = dma_channel_get_default_config(neo_dma);
    channel_config_set_transfer_data_size(&dcfg, DMA_SIZE_32);
    channel_config_set_read_increment(&dcfg, true);
    channel_config_set_write_increment(&dcfg, false);
    channel_config_set_dreq(&dcfg, pio_get_dreq(neo_pio, neo_sm, true));
    dma_channel_configure(neo_dma, &dcfg, &neo_pio->txf[neo_sm], led_data, neopixel::Count, false);

    std::fill(std::begin(led_data), std::end(led_data), 0);
}

void neopixel_set(uint index, uint8_t r, uint8_t g, uint8_t b, uint8_t w) {
    if (index < neopixel::Count) {
        led_data[index] = encode_urgbw(r, g, b, w);
    }
}

void neopixel_set_all(uint8_t r, uint8_t g, uint8_t b, uint8_t w) {
    uint32_t val = encode_urgbw(r, g, b, w);
    std::fill(std::begin(led_data), std::end(led_data), val);
}

void neopixel_clear() {
    neopixel_set_all(0, 0, 0, 0);
}

void neopixel_show() {
    dma_channel_wait_for_finish_blocking(neo_dma);
    sleep_us(60);
    dma_channel_set_read_addr(neo_dma, led_data, false);
    dma_channel_set_trans_count(neo_dma, neopixel::Count, true);
}

} // extern "C"
