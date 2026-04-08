# Top-Level FPGA Block Diagram (Current FCSP Integration)

This is the canonical architectural view for the current FCSP offloader integration at 54 MHz.

> **Module hierarchy and register details:** [DESIGN.md](DESIGN.md)
> **Block responsibilities and implementation status:** [FPGA_BLOCK_DESIGN.md](FPGA_BLOCK_DESIGN.md)

```mermaid
flowchart TD
    %% Host Inputs
    subgraph Host_Ingress [Unified Ingress]
        SPI[SPI: Linux FC Link]
        USB[USB-CDC: Configurator Link]
        ARB{Ingress Priority Mux\nUSB-valid wins over SPI}
    end

    %% Protocol Engine
    subgraph Protocol_Engine [Packet Processing]
        PARSER[FCSP Header Parser\nSync + Header + Length]
        CRC[CRC16/XMODEM Gate\nFrame Valid/Invalid]
        ROUTER{Channel Router}
    end

    %% Actuator Paths
    subgraph Control_Plane [Control Plane - CH: 0x01]
        WB_MASTER[fcsp_wishbone_master\nDirect WB READ/WRITE_BLOCK]
    end

    subgraph Passthrough_Stream [ESC Passthrough - CH: 0x05]
        STREAM_FIFO[Dual-Port Telemetry FIFO\nChannel 0x05 Stream]
        UART_CORE[Half-Duplex UART Engine\nHardware Stream Sync]
    end

    %% Physical IO
    subgraph Actuators [Physical Output Mux]
        DSHOT[DShot Motor Engine]
        NEO[NeoPixel Engine]
        MUX_SWITCH{Hardware Pin Mux\nwith Sniffer & Force Mode}
    end

    %% Connections
    SPI --> ARB
    USB --> ARB
    ARB --> PARSER --> CRC --> ROUTER

    %% Routing
    ROUTER -->|CONTROL| WB_MASTER
    ROUTER -->|ESC_SERIAL| STREAM_FIFO
    STREAM_FIFO <--> UART_CORE

    %% Control Map
    WB_MASTER -.WB bus.-> WB_BUS[[Wishbone / IO Subsystem]]
    WB_BUS <--> DSHOT
    WB_BUS <--> NEO
    WB_BUS <--> UART_CORE : "Baud Rate Config"
    
    %% The Hard Switch
    WB_BUS -.->|Mux/Force Select| MUX_SWITCH
    UART_CORE <--> MUX_SWITCH
    STREAM_FIFO -.->|Auto-Sniff Trigger| MUX_SWITCH

    %% Physical World
    MUX_SWITCH --> PHYSICAL_PINS[Motor ESC 1-4]
    NEO --> PHYSICAL_LED[Status NeoPixels]
```

## Functional Principles

### 1) Deterministic Control Seam
Channel `0x01` is handled by `fcsp_wishbone_master` inside `fcsp_offloader_top`. It decodes READ_BLOCK / WRITE_BLOCK ops and drives the internal Wishbone bus directly — no CPU or firmware involved.

> **Note:** Channel `0x05` (ESC_SERIAL) is fully wired: router → `fcsp_io_engines` → `wb_esc_uart` TX/RX → `fcsp_stream_packetizer` → TX arbiter. See [DESIGN.md](DESIGN.md) §2.7 for the complete datapath.

### 2) Zero-Wait Passthrough
When the `Mode Select` register is set, the motor pins are physically disconnected from the DShot engine and wired to the `ESC_SERIAL` stream. This provides the microsecond-level timing accuracy needed for ESC bootloader entry.

### 3) High-Speed Ingress
Both SPI and USB-CDC flow into the same hardware parser via a **priority selection mux** (USB-valid has precedence when both are active).

## Related Documentation

- [DESIGN.md](DESIGN.md): Master RTL architecture reference (modules, buses, registers, datapaths).
- [FPGA_BLOCK_DESIGN.md](FPGA_BLOCK_DESIGN.md): Block responsibilities and Mermaid diagram.
- [FCSP_PROTOCOL.md](FCSP_PROTOCOL.md): Wire format, channel definitions, CONTROL payload ops.
- [TIMING_REPORT.md](TIMING_REPORT.md): Switch-over timing and FPGA compile analysis.
