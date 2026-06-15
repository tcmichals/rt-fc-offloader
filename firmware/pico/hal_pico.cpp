#include "../hal/hal.h"
#include "pico/stdlib.h"
#include "pico/stdio_usb.h"
#include "hardware/timer.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"
#include "hardware/sync.h"
#include "dshot.h"
#include "debug_uart.h"
#include "msp.h"
#include "../common/esc_passthrough.h"
#include "esc_pio_serial.h"
#include "pico/util/queue.h"
#include <stdio.h>
#include <string.h>

namespace {

static constexpr uint kDebugUartTxPin = 20;
static constexpr uint32_t kDebugUartBaud = 115200;
static volatile bool g_debug_uart_hw_inited = false;

static inline void ensure_debug_uart_hw_init() {
    if (g_debug_uart_hw_inited) {
        return;
    }
    uart_init(uart1, kDebugUartBaud);
    gpio_set_function(kDebugUartTxPin, GPIO_FUNC_UART);
    uart_set_hw_flow(uart1, false, false);
    uart_set_format(uart1, 8, 1, UART_PARITY_NONE);
    g_debug_uart_hw_inited = true;
}

// TLV (Type-Length-Value) encoding for flexible argument passing
enum class TlvType : uint8_t {
    Uint32 = 0,
    Uint64 = 1,
    Ptr = 2,  // String pointer or other pointer
    End = 255
};

struct TlvHeader {
    uint8_t type;
    uint8_t length;
};

static constexpr uint8_t kMaxTlvDataSize = 64;  // Max size per TLV value
static constexpr uint8_t kTlvBufferSize = 128; // Total TLV buffer per log event

struct LogEvent {
    const char* fmt;
    uint8_t tlv_buffer[kTlvBufferSize];  // TLV-encoded arguments
    uint8_t tlv_length;                 // Actual TLV data length
    uint8_t priority;                   // 0=normal (try_add), 1=critical (bounded retry)
};

// Queue RAM cost: 256 * ~136 bytes = ~35KB
static queue_t log_queue;
static volatile bool log_queue_inited = false;
static constexpr uint32_t LogQueueSize = 256; // Reduced due to larger event size
static volatile uint32_t log_drop_count = 0;
static spin_lock_t* g_critical_section_lock = nullptr;

// TLV encoding helper
static bool tlv_encode_uint32(uint8_t* buffer, uint8_t* offset, uint8_t buffer_size, uint32_t value) {
    if (*offset + sizeof(TlvHeader) + sizeof(uint32_t) > buffer_size) {
        return false;
    }
    TlvHeader* hdr = reinterpret_cast<TlvHeader*>(&buffer[*offset]);
    hdr->type = static_cast<uint8_t>(TlvType::Uint32);
    hdr->length = sizeof(uint32_t);
    *offset += sizeof(TlvHeader);
    memcpy(&buffer[*offset], &value, sizeof(uint32_t));
    *offset += sizeof(uint32_t);
    return true;
}

static bool tlv_encode_uint64(uint8_t* buffer, uint8_t* offset, uint8_t buffer_size, uint64_t value) {
    if (*offset + sizeof(TlvHeader) + sizeof(uint64_t) > buffer_size) {
        return false;
    }
    TlvHeader* hdr = reinterpret_cast<TlvHeader*>(&buffer[*offset]);
    hdr->type = static_cast<uint8_t>(TlvType::Uint64);
    hdr->length = sizeof(uint64_t);
    *offset += sizeof(TlvHeader);
    memcpy(&buffer[*offset], &value, sizeof(uint64_t));
    *offset += sizeof(uint64_t);
    return true;
}

static bool tlv_encode_ptr(uint8_t* buffer, uint8_t* offset, uint8_t buffer_size, uintptr_t value) {
    if (*offset + sizeof(TlvHeader) + sizeof(uintptr_t) > buffer_size) {
        return false;
    }
    TlvHeader* hdr = reinterpret_cast<TlvHeader*>(&buffer[*offset]);
    hdr->type = static_cast<uint8_t>(TlvType::Ptr);
    hdr->length = sizeof(uintptr_t);
    *offset += sizeof(TlvHeader);
    memcpy(&buffer[*offset], &value, sizeof(uintptr_t));
    *offset += sizeof(uintptr_t);
    return true;
}

// TLV decoding helper
static bool tlv_decode_next(const uint8_t* buffer, uint8_t buffer_size, uint8_t* offset,
                            TlvType* out_type, const uint8_t** out_value, uint8_t* out_length) {
    if (*offset + sizeof(TlvHeader) > buffer_size) {
        return false;
    }
    const TlvHeader* hdr = reinterpret_cast<const TlvHeader*>(&buffer[*offset]);
    if (hdr->type == static_cast<uint8_t>(TlvType::End)) {
        return false;
    }
    if (*offset + sizeof(TlvHeader) + hdr->length > buffer_size) {
        return false;
    }
    *out_type = static_cast<TlvType>(hdr->type);
    *out_value = &buffer[*offset + sizeof(TlvHeader)];
    *out_length = hdr->length;
    *offset += sizeof(TlvHeader) + hdr->length;
    return true;
}

}

extern "C" {

void hal_init(void) {
    // Initialize the thread-safe debug log queue
    if (!log_queue_inited) {
        queue_init(&log_queue, sizeof(LogEvent), LogQueueSize);
        log_queue_inited = true;
    }
    // Initialize spinlock for critical sections
    if (!g_critical_section_lock) {
        g_critical_section_lock = spin_lock_init(spin_lock_claim_unused(true));
    }
}

void logger_core1_task() {
    if (!log_queue_inited) return;
    LogEvent ev;
    char buf[256];  // Increased buffer for more complex formatting
    // Report any dropped events first so they show up in the stream
    static uint32_t last_reported_drops = 0;
    if (log_drop_count != last_reported_drops) {
        uint32_t dropped = log_drop_count - last_reported_drops;
        last_reported_drops = log_drop_count;
        int len = snprintf(buf, sizeof(buf), "[WARN: %u log events dropped!]\r\n", (unsigned)dropped);
        for (int i = 0; i < len; i++) uart_putc_raw(uart1, (uint8_t)buf[i]);
    }
    while (queue_try_remove(&log_queue, &ev)) {
        if (g_debug_uart_hw_inited) {
            // Decode TLV arguments and format
            uint8_t tlv_offset = 0;
            uint32_t args[8] = {0};  // Support up to 8 arguments
            int arg_count = 0;

            while (tlv_offset < ev.tlv_length && arg_count < 8) {
                TlvType type;
                const uint8_t* value;
                uint8_t length;
                if (!tlv_decode_next(ev.tlv_buffer, ev.tlv_length, &tlv_offset, &type, &value, &length)) {
                    break;
                }
                if (type == TlvType::Uint32 && length == sizeof(uint32_t)) {
                    uint32_t val;
                    memcpy(&val, value, sizeof(uint32_t));
                    args[arg_count++] = val;
                }
                // Add support for other types as needed
            }

            // Core 1 does the heavy snprintf formatting
            int len;
            switch (arg_count) {
                case 0: len = snprintf(buf, sizeof(buf), ev.fmt); break;
                case 1: len = snprintf(buf, sizeof(buf), ev.fmt, args[0]); break;
                case 2: len = snprintf(buf, sizeof(buf), ev.fmt, args[0], args[1]); break;
                case 3: len = snprintf(buf, sizeof(buf), ev.fmt, args[0], args[1], args[2]); break;
                case 4: len = snprintf(buf, sizeof(buf), ev.fmt, args[0], args[1], args[2], args[3]); break;
                case 5: len = snprintf(buf, sizeof(buf), ev.fmt, args[0], args[1], args[2], args[3], args[4]); break;
                case 6: len = snprintf(buf, sizeof(buf), ev.fmt, args[0], args[1], args[2], args[3], args[4], args[5]); break;
                case 7: len = snprintf(buf, sizeof(buf), ev.fmt, args[0], args[1], args[2], args[3], args[4], args[5], args[6]); break;
                case 8: len = snprintf(buf, sizeof(buf), ev.fmt, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]); break;
                default: len = snprintf(buf, sizeof(buf), "[ERROR: too many args]\r\n"); break;
            }

            if (len > 0) {
                for (int i = 0; i < len && i < (int)sizeof(buf); i++) {
                    uart_putc_raw(uart1, static_cast<uint8_t>(buf[i]));
                }
            }
        }
    }
}

uint32_t hal_uptime_us(void) {
    return time_us_32();
}

uint32_t hal_uptime_ms(void) {
    return to_ms_since_boot(get_absolute_time());
}

void     hal_delay_us(uint32_t us) {
    sleep_us(us);
}

int16_t  hal_getc(void) {
    int c = getchar_timeout_us(0);
    if (c == PICO_ERROR_TIMEOUT) return -1;
    return (int16_t)static_cast<uint8_t>(c);
}

void hal_critical_section_enter(void) {
    if (g_critical_section_lock) {
        spin_lock_unsafe_blocking(g_critical_section_lock);
    }
}

void hal_critical_section_exit(void) {
    if (g_critical_section_lock) {
        spin_unlock_unsafe(g_critical_section_lock);
    }
}

void hal_debug_putc(char c) {
    // Char logging is disabled in favor of async printf, but we keep the signature
}

void hal_debug_printf_async(const char* fmt, uint32_t arg1, uint32_t arg2, uint32_t arg3, uint32_t arg4) {
    if (!fmt) return;
    ensure_debug_uart_hw_init();
    if (log_queue_inited) {
        LogEvent ev{};
        ev.fmt = fmt;
        ev.tlv_length = 0;
        ev.priority = 0;

        // Encode arguments as TLV
        tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg1);
        tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg2);
        tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg3);
        tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg4);

        if (!queue_try_add(&log_queue, &ev)) {
            log_drop_count++;
        }
    }
}

void hal_debug_printf_critical(const char* fmt, uint32_t arg1, uint32_t arg2, uint32_t arg3, uint32_t arg4) {
    if (!fmt) return;
    ensure_debug_uart_hw_init();
    if (!log_queue_inited) return;
    LogEvent ev{};
    ev.fmt = fmt;
    ev.tlv_length = 0;
    ev.priority = 1;

    // Encode arguments as TLV
    tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg1);
    tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg2);
    tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg3);
    tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, arg4);

    const uint32_t deadline = time_us_32() + 50;
    while (!queue_try_add(&log_queue, &ev)) {
        if (time_us_32() >= deadline) {
            log_drop_count++;
            return;
        }
    }
}

void hal_debug_puts(const char* s) {
    if (!s) return;
    // Pass string pointer as first argument (arg1)
    hal_debug_printf_async("%s", reinterpret_cast<uintptr_t>(s), 0, 0, 0);
}

void hal_debug_hex(uint32_t val) {
    hal_debug_printf_async("%08X", val, 0, 0, 0);
}

// Variadic logging function for flexible argument passing
void hal_debug_printf_v(const char* fmt, const uint32_t* args, uint8_t arg_count) {
    if (!fmt) return;
    ensure_debug_uart_hw_init();
    if (!log_queue_inited) return;

    LogEvent ev{};
    ev.fmt = fmt;
    ev.tlv_length = 0;
    ev.priority = 0;

    // Encode arguments as TLV (up to 8 args)
    for (uint8_t i = 0; i < arg_count && i < 8; i++) {
        tlv_encode_uint32(ev.tlv_buffer, &ev.tlv_length, kTlvBufferSize, args[i]);
    }

    if (!queue_try_add(&log_queue, &ev)) {
        log_drop_count++;
    }
}

void hal_led_init(void) {
#ifdef PICO_DEFAULT_LED_PIN
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
#endif
}

void hal_led_on(void) {
#ifdef PICO_DEFAULT_LED_PIN
    gpio_put(PICO_DEFAULT_LED_PIN, 1);
#endif
}

void hal_led_off(void) {
#ifdef PICO_DEFAULT_LED_PIN
    gpio_put(PICO_DEFAULT_LED_PIN, 0);
#endif
}

void hal_dshot_write(uint8_t channel, uint16_t value) {
    if (channel < dshot::MaxMotors) {
        dshot_write(channel, value, false);
        // On Pico, we usually call dshot_update_all() after a batch of writes.
        // The common app logic should handle the batching.
    }
}

bool hal_dshot_is_passthrough_active(uint8_t channel) {
    // On Pico, this is derived from the MSP/4-way state
    return msp_passthrough_is_active();
}

void hal_dshot_set_passthrough(uint8_t channel, bool active) {
    if (active) {
        // Entering passthrough: disable DSHOT on this line
        dshot_force_stop_all();
        // Hardware pin muxing for UART/bitbanging
        uint pin = motors_get_pin(channel);
        if (pin != 0) {
            esc_pio_serial_start(pin, 19200); // Default BLHeli baud
        }
    } else {
        // Exiting passthrough: restore pin to DSHOT PIO
        esc_pio_serial_stop();
        // Hardware pin muxing restoration
        uint pin = motors_get_pin(channel);
        if (pin != 0) {
            pio_gpio_init(dshot::Inst, pin);
        }
        // The dshot_update_all() will automatically re-enable the SM when normal operation resumes.
    }
}

void hal_esc_serial_putc(uint8_t channel, uint8_t c) {
    esc_pio_serial_write_byte(c);
}

int16_t hal_esc_serial_getc(uint8_t channel) {
    uint8_t out_value;
    if (esc_pio_serial_read_byte(&out_value)) {
        return out_value;
    }
    return -1;
}

} // extern "C"
