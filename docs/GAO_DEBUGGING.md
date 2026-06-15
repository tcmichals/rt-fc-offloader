# Debugging with Gowin Analyzer Oscilloscope (GAO)

With the transition to the official Gowin toolchain, you now have access to a powerful hardware-level Integrated Logic Analyzer (ILA) called **GAO**. 

GAO allows you to passively probe any internal wire, state machine, or bus in your Verilog design and view a live, high-speed waveform of those signals directly on your PC monitor over the USB JTAG cable.

Because GAO uses the FPGA's internal Block RAM (BSRAM) to store its sample data, and our heavily optimized design currently only uses 2 out of 26 BSRAM blocks (8%), we have an enormous amount of memory available for high-resolution waveform captures!

## How to Setup and Use GAO

### 1. Launch GAO
1. Open the Gowin IDE (`gw_ide`).
2. Open your Tang Nano 9K project (`tangnano9k.gprj`).
3. On the top menu bar, click **Tools -> Gowin Analyzer Oscilloscope**.

### 2. Create a GAO Project (.rao)
1. In the GAO window, click **File -> New**.
2. Select your top-level module (`fcsp_tangnano9k_top`).
3. Select your system clock (`sys_clk`) as the Sampling Clock. This guarantees that GAO samples your data synchronously with your logic.

### 3. Select Signals to Probe
1. Go to the **Signal** tab.
2. Click **Add Signal** and expand the netlist hierarchy. 
3. You can click on any wire or register. For example, to view the DShot state machine, navigate to `u_io_engines -> u_dshot` and select `state` and `o_motor`. 
4. To replace the legacy serial debug stream, you can navigate into `fcsp_offloader_top` and select the `probe_snapshot[31:0]` bus or any of the raw signals like `router_ctrl_tvalid`.

### 4. Set Trigger Conditions (Optional but Recommended)
1. Go to the **Trigger** tab.
2. Set a trigger condition so GAO knows when to start recording. 
3. For example, if you want to capture an SPI transaction, set the trigger condition to: `i_spi_cs_n == 0` (Falling edge). 
4. GAO will constantly record data into a circular buffer, but will only "lock" and send the waveform to your screen when the trigger hits.

### 5. Compile and Inject
1. Save the GAO configuration (`.rao` file).
2. The Gowin IDE will automatically prompt you to re-run the **Place & Route** phase.
3. The Gowin router will automatically inject the GAO IP Core into your bitstream.
4. Flash the new `.fs` bitstream to your Tang Nano 9K.

### 6. View Live Waveforms!
1. In the GAO window, click the **Connect** button to establish a JTAG link with your Tang Nano 9K over USB.
2. Click **Run**.
3. Trigger the event (e.g., send an SPI command from the Pico).
4. Boom! A beautiful, real-time logic analyzer waveform will pop up on your screen.

## Note on the Legacy Serial Soft-ILA
The legacy `fcsp_debug_generator.sv` serial stream has been intentionally disabled in `fcsp_tangnano9k_top.sv` (tied off to `1'b0`) to save SPI bandwidth and reduce unnecessary Wishbone traffic, as the hardware GAO completely supersedes its functionality.
