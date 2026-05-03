#pragma once

#include <stdint.h>

namespace debug_uart {

void init();
void write(const char *text);
void writef(const char *fmt, ...);
void write_ts(const char *text);
void writef_ts(const char *fmt, ...);

} // namespace debug_uart
