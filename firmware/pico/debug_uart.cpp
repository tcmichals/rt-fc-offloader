#include "debug_uart.h"

#include "pico/stdlib.h"
#include "pico/critical_section.h"
#include "hardware/gpio.h"
#include "hardware/irq.h"
#include "hardware/structs/uart.h"
#include "hardware/uart.h"
#include <cstdarg>
#include <cstdio>

namespace debug_uart {
namespace {

static constexpr bool Enabled = true;
static uart_inst_t *const DebugUart = uart1;
static constexpr uint DebugUartTxPin = 4;
static constexpr uint32_t DebugUartBaud = 115200;
static constexpr uint16_t TxBufferSize = 1024;
static constexpr uint16_t TxBufferMask = TxBufferSize - 1;
static constexpr uint16_t RateLimitBytesPerSecond = 2048;
static constexpr uint16_t RateLimitBurstBytes = 256;
static_assert((TxBufferSize & (TxBufferSize - 1)) == 0, "TxBufferSize must be a power of two");

static critical_section_t tx_lock;
static bool tx_lock_inited = false;
static bool uart_inited = false;
static uint8_t tx_buffer[TxBufferSize] = {};
static uint16_t tx_head = 0;
static uint16_t tx_tail = 0;
static uint16_t rl_tokens = RateLimitBurstBytes;
static uint32_t rl_last_refill_us = 0;

static inline uint16_t tx_count_locked() {
    return static_cast<uint16_t>(tx_head - tx_tail);
}

static inline void ensure_lock_init() {
    if (!tx_lock_inited) {
        critical_section_init(&tx_lock);
        tx_lock_inited = true;
    }
}

static inline void refill_tokens_locked() {
    const uint32_t now_us = time_us_32();
    if (rl_last_refill_us == 0) {
        rl_last_refill_us = now_us;
        rl_tokens = RateLimitBurstBytes;
        return;
    }

    const uint32_t elapsed_us = static_cast<uint32_t>(now_us - rl_last_refill_us);
    if (elapsed_us == 0) {
        return;
    }

    const uint32_t add = (elapsed_us * RateLimitBytesPerSecond) / 1000000u;
    if (add == 0) {
        return;
    }

    rl_last_refill_us = now_us;
    const uint32_t new_tokens = static_cast<uint32_t>(rl_tokens) + add;
    rl_tokens = static_cast<uint16_t>(new_tokens > RateLimitBurstBytes ? RateLimitBurstBytes : new_tokens);
}

static inline void drain_tx_fifo_locked() {
    while (tx_head != tx_tail && uart_is_writable(DebugUart)) {
        uart_get_hw(DebugUart)->dr = tx_buffer[tx_tail & TxBufferMask];
        ++tx_tail;
    }
}

static inline void enable_tx_irq_locked() {
    uart_set_irq_enables(DebugUart, false, true);
}

static inline void disable_tx_irq_locked() {
    uart_set_irq_enables(DebugUart, false, false);
}

void on_uart_irq() {
    if (!uart_inited) {
        return;
    }

    critical_section_enter_blocking(&tx_lock);
    drain_tx_fifo_locked();
    if (tx_head == tx_tail) {
        disable_tx_irq_locked();
    }
    critical_section_exit(&tx_lock);
}

static void enqueue_bytes(const char *text) {
    if (!Enabled || !uart_inited || !text) {
        return;
    }

    critical_section_enter_blocking(&tx_lock);
    refill_tokens_locked();
    while (*text) {
        if (rl_tokens == 0) {
            break;
        }
        if (tx_count_locked() >= TxBufferSize) {
            break;
        }
        tx_buffer[tx_head & TxBufferMask] = static_cast<uint8_t>(*text++);
        ++tx_head;
        --rl_tokens;
    }
    drain_tx_fifo_locked();
    if (tx_head != tx_tail) {
        enable_tx_irq_locked();
    }
    critical_section_exit(&tx_lock);
}

static void enqueue_timestamp_prefix() {
    char prefix[24];
    const uint64_t now_us = time_us_64();
    const uint32_t sec = static_cast<uint32_t>(now_us / 1000000u);
    const uint32_t ms = static_cast<uint32_t>((now_us / 1000u) % 1000u);
    const int n = std::snprintf(prefix, sizeof(prefix), "[%lu.%03lu] ",
                                static_cast<unsigned long>(sec),
                                static_cast<unsigned long>(ms));
    if (n > 0) {
        enqueue_bytes(prefix);
    }
}

} // namespace

void init() {
    ensure_lock_init();
    if (!Enabled || uart_inited) {
        return;
    }

    uart_init(DebugUart, DebugUartBaud);
    gpio_set_function(DebugUartTxPin, GPIO_FUNC_UART);
    uart_set_hw_flow(DebugUart, false, false);
    uart_set_format(DebugUart, 8, 1, UART_PARITY_NONE);
    irq_set_exclusive_handler(UART1_IRQ, on_uart_irq);
    irq_set_enabled(UART1_IRQ, true);
    disable_tx_irq_locked();
    rl_last_refill_us = time_us_32();
    rl_tokens = RateLimitBurstBytes;
    uart_inited = true;
}

void write(const char *text) {
    enqueue_bytes(text);
}

void writef(const char *fmt, ...) {
    if (!Enabled || !uart_inited || !fmt) {
        return;
    }

    char line[256];
    va_list args;
    va_start(args, fmt);
    const int n = std::vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (n <= 0) {
        return;
    }
    line[sizeof(line) - 1] = '\0';
    enqueue_bytes(line);
}

void write_ts(const char *text) {
    if (!Enabled || !uart_inited || !text) {
        return;
    }
    enqueue_timestamp_prefix();
    enqueue_bytes(text);
}

void writef_ts(const char *fmt, ...) {
    if (!Enabled || !uart_inited || !fmt) {
        return;
    }

    char line[256];
    va_list args;
    va_start(args, fmt);
    const int n = std::vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (n <= 0) {
        return;
    }

    line[sizeof(line) - 1] = '\0';
    enqueue_timestamp_prefix();
    enqueue_bytes(line);
}

} // namespace debug_uart
