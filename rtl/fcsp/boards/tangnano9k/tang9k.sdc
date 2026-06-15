create_clock -name i_clk -period 20.000 [get_ports {i_clk}]

# PLL output: 54 MHz (27 * 2 / 1). This is the actual system clock domain.
create_clock -name sys_clk -period 18.519 [get_nets {sys_clk}]

# External SPI clock domain comes from host and is treated as asynchronous to
# sys_clk in this initial board wrapper.
create_clock -name i_spi_clk -period 100.0 [get_ports {i_spi_clk}]

# Formally declare them as asynchronous so the Timing Analyzer stops complaining
# Note: Commented out because NextPNR (OSS toolchain) does not support 'get_clocks'
# set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {i_spi_clk}]