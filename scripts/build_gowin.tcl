set_device GW1NR-LV9QN88PC6/I5
add_file -type verilog "rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv"
add_file -type verilog "rtl/fcsp/fcsp_offloader_top.sv"
add_file -type verilog "rtl/fcsp/fcsp_spi_frontend.sv"
add_file -type verilog "rtl/fcsp/fcsp_parser.sv"
add_file -type verilog "rtl/fcsp/fcsp_crc16_core_xmodem.sv"
add_file -type verilog "rtl/fcsp/fcsp_crc16.sv"
add_file -type verilog "rtl/fcsp/fcsp_crc_gate.sv"
add_file -type verilog "rtl/fcsp/fcsp_router.sv"
add_file -type verilog "rtl/fcsp/fcsp_rx_fifo.sv"
add_file -type verilog "rtl/fcsp/fcsp_tx_fifo.sv"
add_file -type verilog "rtl/fcsp/fcsp_tx_arbiter.sv"
add_file -type verilog "rtl/fcsp/fcsp_tx_framer.sv"
add_file -type verilog "rtl/fcsp/fcsp_uart_byte_stream.sv"
add_file -type verilog "rtl/fcsp/fcsp_io_engines.sv"
add_file -type verilog "rtl/fcsp/fcsp_wishbone_master.sv"
add_file -type verilog "rtl/fcsp/fcsp_stream_packetizer.sv"
add_file -type verilog "rtl/fcsp/fcsp_debug_generator.sv"
add_file -type verilog "rtl/fcsp/drivers/wb_led_controller.sv"
add_file -type verilog "rtl/io/wb_io_bus.sv"
add_file -type verilog "rtl/io/wb_dshot_controller.sv"
add_file -type verilog "rtl/io/dshot_out.sv"
add_file -type verilog "rtl/io/wb_serial_dshot_mux.sv"
add_file -type verilog "rtl/io/wb_esc_uart.sv"
add_file -type verilog "rtl/io/wb_neoPx.sv"
add_file -type verilog "rtl/io/sendPx_axis_flexible.sv"
add_file -type verilog "rtl/io/pwmdecoder_wb.sv"
add_file -type cst "rtl/fcsp/boards/tangnano9k/tang9k.cst"
add_file -type sdc "rtl/fcsp/boards/tangnano9k/tang9k.sdc"
set_option -top_module fcsp_tangnano9k_top
set_option -verilog_std sysv2017
set_option -use_sspi_as_gpio 1
run syn
run pnr
