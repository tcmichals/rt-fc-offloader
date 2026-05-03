#pragma once

#include <stdint.h>

namespace timing_config {

// Main control loop / DSHOT scheduling
static constexpr uint32_t WatchdogTimeoutUs = 1000000u;
static constexpr uint32_t DshotFramePeriodUs = 1000u;

// Passthrough lifecycle
static constexpr uint32_t DshotResumeDelayUs = 1000000u;
static constexpr uint32_t PassthroughIdleExitUs = 1000000u;

// USB startup / enumeration
static constexpr uint32_t UsbEnumerateWaitMs = 2500u;
static constexpr uint32_t UsbSettleDelayMs = 250u;
static constexpr uint32_t UsbPollStepMs = 10u;

} // namespace timing_config
