create_clock -name i_clk -period 20.000 [get_ports {i_clk}]

# PLL output: 54 MHz (27 * 2 / 1). This is the actual system clock domain.
create_clock -name sys_clk -period 18.519 [get_nets {sys_clk}]

# External SPI clock domain comes from host and is treated as asynchronous to
# sys_clk in this initial board wrapper.
create_clock -name i_spi_clk -period 100.0 [get_ports {i_spi_clk}]

# TODO: Add board-specific I/O and false path constraints for Tang Nano 20K as
# needed for a real physical build.
