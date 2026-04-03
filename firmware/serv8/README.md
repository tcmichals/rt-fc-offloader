# firmware/serv8 — CONTROL-plane firmware

SERV 8-bit firmware owns policy/state logic while RTL handles frame fast-path.

## Responsibilities

- CONTROL op dispatch and result code mapping
- passthrough ownership/state transitions
- capability response generation (`HELLO`, `GET_CAPS`)
- dynamic block IO policy (`READ_BLOCK`, `WRITE_BLOCK`)

## Initial op implementation order

1. `PING` / `GET_LINK_STATUS`
2. `HELLO` / `GET_CAPS`
3. `PT_ENTER` / `PT_EXIT` / `ESC_SCAN`
4. `SET_MOTOR_SPEED`
5. `READ_BLOCK` / `WRITE_BLOCK`

## Guardrails

- no per-byte ISR flow in nominal operation
- deterministic result/error code behavior
- block DSHOT writes during passthrough ownership
