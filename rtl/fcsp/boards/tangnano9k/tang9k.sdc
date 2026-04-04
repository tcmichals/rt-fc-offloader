create_clock -name i_clk -period 37.037 [get_ports {i_clk}]

# External SPI clock domain comes from host and is treated as asynchronous to
# i_clk in this initial board wrapper.
create_clock -name i_spi_clk -period 100.0 [get_ports {i_spi_clk}]