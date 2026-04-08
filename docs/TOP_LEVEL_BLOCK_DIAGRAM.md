# Top-Level FPGA Block Diagram (Current FCSP Integration)

This is the canonical architectural view for the current FCSP offloader integration at 54 MHz.

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
        SERV_BRIDGE[fcsp_serv_bridge\nFCSP<->SERV Stream Adapter]
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
    ROUTER -->|CONTROL| SERV_BRIDGE
    ROUTER -->|ESC_SERIAL| STREAM_FIFO
    STREAM_FIFO <--> UART_CORE

    %% Control Map
    SERV_BRIDGE -.serv cmd/rsp.-> WB_BUS[[Wishbone / IO Subsystem]]
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
Channel `0x01` is currently handled by `fcsp_serv_bridge` at the top-level seam.
This is a legacy stream-adapter module name, not an indication that an embedded soft CPU is in use.

### 2) Zero-Wait Passthrough
When the `Mode Select` register is set, the motor pins are physically disconnected from the DShot engine and wired to the `ESC_SERIAL` stream. This provides the microsecond-level timing accuracy needed for ESC bootloader entry.

### 3) High-Speed Ingress
Both SPI and USB-CDC flow into the same hardware parser via a **priority selection mux** (USB-valid has precedence when both are active).

## Related Documentation

- `docs/FPGA_BLOCK_DESIGN.md`: Deep dive into block implementation.
- `docs/FCSP_PROTOCOL.md`: Wire-format and register map details.
- `docs/TIMING_REPORT.md`: Detailed switch-over timing analysis.
