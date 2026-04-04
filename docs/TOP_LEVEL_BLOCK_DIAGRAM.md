# Top-Level FPGA Block Diagram (Pure Hardware FCSP)

This is the canonical architectural view for the **CPU-less** FCSP offloader. All functions are performed in high-speed RTL gates at 54 MHz.

```mermaid
flowchart TD
    %% Host Inputs
    subgraph Host_Ingress [Unified Ingress]
        SPI[SPI: Linux FC Link]
        USB[USB-CDC: Configurator Link]
        ARB{Ingress Arbiter}
    end

    %% Protocol Engine
    subgraph Protocol_Engine [Packet Processing]
        PARSER[FCSP Header Parser\nSync + Header + Length]
        CRC[CRC16/XMODEM Gate\nFrame Valid/Invalid]
        ROUTER{Channel Router}
    end

    %% Actuator Paths
    subgraph Control_Plane [Actuation Plane - CH: 0x01]
        WB_MASTER[Wishbone Master\nREAD/WRITE_BLOCK Executor]
        WB_BUS[[Internal Wishbone Bus]]
    end

    subgraph Passthrough_Plane [ESC Passthrough - CH: 0x05]
        ESC_TUNNEL[Serial Byte Tunnel\n1-Wire Half-Duplex]
    end

    %% Physical IO
    subgraph Actuators [Physical Output Mux]
        DSHOT[DShot Motor Engine]
        NEO[NeoPixel Engine]
        MUX_SWITCH{Hardware Pin Mux}
    end

    %% Connections
    SPI --> ARB
    USB --> ARB
    ARB --> PARSER --> CRC --> ROUTER

    %% Routing
    ROUTER -->|CONTROL| WB_MASTER
    ROUTER -->|ESC_SERIAL| ESC_TUNNEL

    %% Control Map
    WB_MASTER <--> WB_BUS
    WB_BUS <--> DSHOT
    WB_BUS <--> NEO
    
    %% The Hard Switch (Reg 0x20)
    WB_BUS -.->|Mode Select| MUX_SWITCH
    ESC_TUNNEL <--> MUX_SWITCH

    %% Physical World
    MUX_SWITCH --> PHYSICAL_PINS[Motor ESC 1-4]
    NEO --> PHYSICAL_LED[Status NeoPixels]
```

## Functional Principles

### 1) Deterministic Control
Command execution (Channel `0x01`) is handled by a state machine that translates FCSP packets directly into Wishbone bus cycles. There is **no software jitter** or interrupt latency.

### 2) Zero-Wait Passthrough
When the `Mode Select` register is set, the motor pins are physically disconnected from the DShot engine and wired to the `ESC_SERIAL` stream. This provides the microsecond-level timing accuracy needed for ESC bootloader entry.

### 3) High-Speed Ingress
Both SPI and USB-CDC flow into the same hardware parser. The **Ingress Arbiter** ensures that commands from either source are processed sequentially and safely.

## Related Documentation

- `docs/FPGA_BLOCK_DESIGN.md`: Deep dive into block implementation.
- `docs/FCSP_PROTOCOL.md`: Wire-format and register map details.
- `docs/TIMING_REPORT.md`: Detailed switch-over timing analysis.
