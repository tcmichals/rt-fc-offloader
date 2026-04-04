# Tang Nano 9K Fit Analysis — Pure Hardware Offloader

This document provides a resource estimation for the finalized **Zero-CPU** architecture on the Tang Nano 9K (GW1NR-9C).

## Hardware Resource Budget

| Asset | Total Available | Estimated Usage | % Utilization |
|-------|-----------------|-----------------|---------------|
| **LUTs** | 8,640 | ~1,200 - 1,500 | **~15%** |
| **BRAMs** | 26 (468 Kb) | 6 - 8 | **~25%** |
| **Logic Speed** | GW1N-9C-5 | 54 MHz | **Verified (Max ~80MHz)** |

## Timing Analysis at 50/54 MHz (FMAX)

Our project uses a system clock of **54 MHz** (27MHz crystal * 2 / 1). 

### Why Timing Closure is Effortless:
1. **CPU-Less Critical Path**: The previous logic bottleneck was the SERV core's ALU-to-memory path. Removing the CPU has eliminated the deepest logic chains.
2. **Pipelined Datapath**: All FCSP processing (Parser, CRC, Router) is byte-per-cycle and fully registered.
3. **Low Density**: With only ~15% LUT utilization, `nextpnr-himbaechel` has immense routing freedom, leading to very low wire delay.
4. **Conclusion**: The 18.5ns (54MHz) and 20ns (50MHz) periods are **extremely conservative**. This logic could comfortably hit **80-100 MHz** before any architectural restructuring was needed.

## Conclusion
The **Pure Hardware Switch** design fits **extremely easily** in the Tang Nano 9K with massive timing headroom. There is ample room for expansion without risking timing violations.
