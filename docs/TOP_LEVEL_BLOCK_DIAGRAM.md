# Top-Level FPGA Block Diagram (FCSP Hot Path)

This is the quick-reference top-level view for the FCSP offloader architecture.

Use this as the canonical top-level block diagram for FPGA datapath/control reviews.

Related docs:

- `docs/FPGA_BLOCK_DESIGN.md` (expanded architecture details)
- `docs/assets/fpga_fcsp_lift_based_diagram.txt` (text-first diagram showing reusable/liftable legacy blocks)
- `external/python-imgui-esc-configurator/docs/architecture.md` (historical/supporting context in submodule)

```mermaid
flowchart LR
    SPI[SPI Front-End\nRX/TX Byte Stream] --> RXARB[RX Transport Arbiter]
    USB[USB Serial Front-End\nCDC/UART Byte Stream] --> RXARB
    RXARB --> PARSER[FCSP Parser\nSync + Header + Length]
    PARSER --> CRC[CRC16/XMODEM Gate\nFrame Valid/Invalid]
    CRC --> ROUTER[Channel Router]

    ROUTER --> Q1[CONTROL FIFO]
    ROUTER --> Q2[TELEMETRY FIFO]
    ROUTER --> Q3[FC_LOG FIFO]
    ROUTER --> Q4[DEBUG_TRACE FIFO]
    ROUTER --> Q5[ESC_SERIAL FIFO]

    Q1 --> SERV[SERV8 Control Plane\nOp Dispatch + Policy]
    SERV --> TXMUX[TX Priority Mux]

    Q2 --> TXMUX
    Q3 --> TXMUX
    Q4 --> TXMUX
    Q5 --> TXMUX

    TXMUX --> TXFR[FCSP TX Framer\nHeader + CRC16]
    TXFR --> TXSEL[TX Transport Mux]
    TXSEL --> SPI
    TXSEL --> USB

    SERV --> IOSPACE[Block IO Windows\nPWM/DSHOT/LED/NEO]
    SERV --> STATUS[Error + Link Counters]
    STATUS --> TXMUX
```

## Key rule

- **Hot SPI path is RTL-only** (`Parser -> CRC -> Router -> FIFOs`).
- **SERV is not in raw-byte path**; it handles validated CONTROL frames and policy.
- **USB serial is optional alternate transport** and must converge to the same FCSP parser/router semantics.

## Lift-first text view

If you want a review-friendly FPGA diagram with explicit `LIFT / ADAPT / NEW` tags, use:

- `docs/assets/fpga_fcsp_lift_based_diagram.txt`

Reading tip: the text diagram is drawn as two clearly separated lanes (`SPI LANE` on the left, `USB SERIAL LANE` on the right) that merge only at `RX Transport Arbiter`.

## Minimal interface boundary

- RTL-to-SERV handoff happens at channel FIFOs using complete frame payload context.
- SERV returns response payloads to TX path through `TX Priority Mux` + `TX Framer`.
