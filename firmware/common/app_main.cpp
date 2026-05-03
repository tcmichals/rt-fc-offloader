#include "../hal/hal.h"
#include "msp.h"
#include "timing_config.h"

// --- Thread States ---
static struct pt pt_msp;

extern "C" {

void app_setup(void) {
    hal_init();
    msp_init();
    PT_INIT(&pt_msp);
    
    hal_debug_puts("\r\n--- Unified App Starting ---\r\n");
}

void app_run_iteration(void) {
    // 1. Run MSP & Passthrough Logic
    msp_task(&pt_msp);
    
    // 2. Run SPI Host Bridge Logic
    // hal_spi_task(); // Future: SPI bridge refactor
    
    // 3. Failsafe & Heartbeat logic
    // ...
}

} // extern "C"
