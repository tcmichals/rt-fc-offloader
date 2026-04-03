# GitHub TODO — rt-fc-offloader

## Current focus

- [ ] Finalize FCSP CONTROL op implementation skeleton
- [ ] Implement `READ_BLOCK` / `WRITE_BLOCK` spaces for dynamic IO
- [ ] Implement `HELLO` + `GET_CAPS` discovery path

## RTL/firmware tasks

- [ ] `rtl/fcsp/`: parser, CRC gate, channel router, FIFO boundaries
- [ ] `firmware/serv8/`: control op dispatcher + result code mapping
- [ ] Define stable IO space map for PWM/DSHOT/LED/NeoPixel windows

## Simulation

- [ ] Add frame parser noise-resync tests
- [ ] Add caps paging tests
- [ ] Add passthrough safety transition tests

## Integration tasks

- [ ] Validate FCSP over primary SPI profile
- [ ] Validate FCSP semantic equivalence over simulation transport
- [ ] Publish migration notes for Python adapter consumers
