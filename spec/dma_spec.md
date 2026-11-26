# DMA controller specification

A single-channel memory-to-memory DMA. Software programs it over APB4; it moves
data over an AXI4 master, one burst at a time. The RTL and the testbench
reference model are both built from this document, not from each other.

## Interfaces

| Port group | Details |
|---|---|
| Clock, reset | One clock `clk`. Active-low **synchronous** reset `rst_n`. |
| APB4 slave | 12-bit byte address (4 KB window), 32-bit data, `PSTRB` byte enables. Zero wait states. `PSLVERR` = 1 for any access to an unmapped offset. Writes to read-only registers are ignored (no error). |
| AXI4 master | 32-bit address, 32-bit data, 1-bit ID (always 0). Fixed: `AxSIZE=3'b010` (4 bytes), `AxBURST=2'b01` (INCR), `AxLOCK=0`, `AxCACHE=0`, `AxPROT=0`, `AxQOS=0`, `WSTRB=4'b1111`. |
| Interrupt | `irq`, active-high level. |

## Register map

| Offset | Name | Fields | Access | Reset |
|---|---|---|---|---|
| 0x00 | VERSION | [31:0] version | RO | 0x0001_0000 |
| 0x04 | INT_STATUS | [0] DONE, [1] ERR | W1C, set by hardware | 0 |
| 0x08 | INT_ENABLE | [0] DONE, [1] ERR | RW | 0 |
| 0x0C | SRC | [31:0] source byte address | RW | 0 |
| 0x10 | DST | [31:0] destination byte address | RW | 0 |
| 0x14 | LEN | [31:0] length in bytes | RW | 0 |
| 0x18 | CTRL | [0] START (write 1 to start, reads 0); [15:8] MAX_BURST = beats per burst − 1 | START: W, pulse. MAX_BURST: RW | MAX_BURST = 0x0F |
| 0x1C | STATUS | [0] BUSY, [1] DONE, [2] ERR, [5:4] ERR_CODE | RO | 0 |

ERR_CODE: 0 = none, 1 = configuration error, 2 = read response error, 3 = write response error.

## Behavior rules

1. **Start.** Writing START = 1 while idle copies SRC, DST, LEN and MAX_BURST into
   internal registers, sets BUSY and clears STATUS.DONE, STATUS.ERR and ERR_CODE.
   A single CTRL write that sets START and changes MAX_BURST uses the new MAX_BURST.
2. **Start while busy** is ignored. The running transfer continues unchanged.
3. **Writes while busy.** SRC, DST, LEN and MAX_BURST may be written; the running
   transfer keeps using its internal copies.
4. **Config error.** If SRC, DST or LEN is not a multiple of 4, or LEN > 0 and the
   last byte of either range (SRC + LEN − 1 or DST + LEN − 1, computed in 33 bits)
   is above 0xFFFF_FFFF: no bus traffic, STATUS.ERR = 1, ERR_CODE = 1, BUSY = 0,
   INT_STATUS.ERR is set.
5. **Zero length.** If the alignment checks pass and LEN = 0: no bus traffic,
   STATUS.DONE = 1, INT_STATUS.DONE is set.
6. **Burst size.** Each burst moves N beats, N = min(words remaining, MAX_BURST + 1,
   words left before the next 4 KB boundary from the current source address, same
   for the destination address). No burst crosses a 4 KB boundary on either side.
7. **One burst at a time.** Read N beats (AR, then R) into the FIFO. If every beat
   is OKAY, write them (AW and W), then wait for B. Then advance both addresses by
   4N and the remaining count by N. Only one AXI transaction is in flight.
8. **Handshakes.** VALID never waits for READY. AWVALID and the first WVALID are
   raised in the same cycle without waiting on each other. RREADY and BREADY are
   held high while the DMA waits for R or B.
9. **Read error.** If any R beat is SLVERR or DECERR, the DMA still accepts every
   beat of that burst, discards the data, does not write that burst and stops:
   STATUS.ERR = 1, ERR_CODE = 2, BUSY = 0, INT_STATUS.ERR is set.
10. **Write error.** If B is SLVERR or DECERR, the DMA stops after that burst:
    STATUS.ERR = 1, ERR_CODE = 3, BUSY = 0, INT_STATUS.ERR is set. Data already
    written stays written.
11. **Completion.** When no words remain: STATUS.DONE = 1, BUSY = 0, INT_STATUS.DONE is set.
12. **Interrupt.** `irq = |(INT_STATUS & INT_ENABLE)`. It stays high until software
    clears the status bits. A hardware set wins over a software clear in the same
    cycle. A new START does **not** clear INT_STATUS (only software does).
13. **Overlap.** Overlapping source and destination ranges give undefined results.
14. **Reset** returns every register to its reset value. Reset is only applied while idle.

## Timing (informative)

- START takes effect one clock after the APB write completes.
- STATUS and INT_STATUS update one clock after the event that sets them.

## Worked example

SRC = 0x0000_0FE0, DST = 0x0000_2000, LEN = 80 bytes (20 words), MAX_BURST = 15.

| Burst | Source | Destination | Beats | Limited by |
|---|---|---|---|---|
| 1 | 0x0000_0FE0 | 0x0000_2000 | 8 | source 4 KB boundary |
| 2 | 0x0000_1000 | 0x0000_2020 | 12 | words remaining |

Then DONE.
