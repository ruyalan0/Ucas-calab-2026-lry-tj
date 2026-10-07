"""Generate end-to-end instruction/commit expectations, independent of RTL internals."""
from pathlib import Path

out = Path(__file__).resolve().parent
code, expected = [], []
regs = [0] * 32
mem = bytearray(4096)
stores = 0

def emit(insn, rd=0, value=0):
    pc = 0x1c000000 + len(code) * 4
    code.append(insn)
    if rd:
        regs[rd] = value & 0xffffffff
        expected.append((pc, rd, regs[rd]))

def li(rd, value):
    value &= 0xffffffff
    emit((5 << 26) | ((value >> 12) << 5) | rd, rd, value & 0xfffff000)
    emit((0xe << 22) | ((value & 4095) << 10) | (rd << 5) | rd, rd, value)

def addi(rd, rj, value):
    emit((0xa << 22) | ((value & 4095) << 10) | (rj << 5) | rd, rd, regs[rj] + value)

def load(kind, rd, base, off):
    widths = {0: 1, 1: 2, 2: 4, 8: 1, 9: 2}
    addr = regs[base] + off
    val = int.from_bytes(mem[addr:addr+widths[kind]], 'little', signed=kind in (0, 1))
    emit((0xa << 26) | (kind << 22) | ((off & 4095) << 10) | (base << 5) | rd, rd, val)

def store(kind, rd, base, off):
    global stores
    width = {4: 1, 5: 2, 6: 4}[kind]
    addr = regs[base] + off
    mem[addr:addr+width] = regs[rd].to_bytes(4, 'little')[:width]
    emit((0xa << 26) | (kind << 22) | ((off & 4095) << 10) | (base << 5) | rd)
    stores += 1

li(1, 256)
li(2, 0x80ff7f01)
store(6, 2, 1, 0)
for kind, offsets in [(0, range(4)), (8, range(4)), (1, (0, 2)), (9, (0, 2)), (2, (0,))]:
    for offset in offsets:
        load(kind, 3, 1, offset)
        addi(4, 3, 1)  # immediate load-use
li(5, 260)
load(0, 3, 5, -1)
load(0, 0, 5, -1)
addi(4, 0, 1)
for kind, offsets in [(4, range(4)), (5, (0, 2))]:
    for offset in offsets:
        li(2, 0x11223344)
        store(6, 2, 1, 0)
        li(2, 0xdeadbeef if kind == 5 else 0x123456aa)
        store(kind, 2, 1, offset)
        load(2, 3, 1, 0)
        load(0 if kind == 4 else 1, 4, 1, offset)
# Load -> store data/address, latest writer, mixed widths.
load(0, 2, 1, 3)
store(4, 2, 1, 4)
li(2, 280)
store(6, 2, 1, 8)
load(2, 5, 1, 8)
store(5, 2, 5, 0)
load(9, 3, 5, 0)
addi(3, 0, 7)
load(0, 3, 1, 3)
addi(4, 3, 1)

def signed(v):
    return v if v < 0x80000000 else v - 0x100000000

# Every pair of boundary values, both operand forwarding paths and wrong-path store.
for op in range(0x18, 0x1c):
    for a in (0, 1, 0xffffffff, 0x80000000, 0x7fffffff):
        for b in (0, 1, 0xffffffff, 0x80000000, 0x7fffffff):
            li(6, a)
            li(7, b)
            less = signed(a) < signed(b) if op < 0x1a else a < b
            taken = less if op in (0x18, 0x1a) else not less
            emit((op << 26) | (2 << 10) | (6 << 5) | 7)
            if taken:
                emit((0xa << 26) | (6 << 22) | (1 << 5) | 6)
            else:
                store(6, 6, 1, 16)
            addi(8, 0, 123)
# Negative branch offset: decrement r9 from 3 to zero.
addi(9, 0, 3)
loop_pc = 0x1c000000 + len(code) * 4
addi(9, 9, -1)
emit((0x18 << 26) | (0xffff << 10) | 9)  # blt r0,r9,-4
expected.extend([(loop_pc, 9, 1), (loop_pc, 9, 0)])
regs[9] = 0
# Load -> branch, signed extension required; squash one store.
li(2, 0x80000000)
store(6, 2, 1, 0)
load(0, 6, 1, 3)
emit((0x18 << 26) | (2 << 10) | (6 << 5))
emit((0xa << 26) | (6 << 22) | (1 << 5) | 6)
# Real multiplier/divider, branch blocked behind division and newest writer.
addi(6, 0, 21)
addi(7, 0, 3)
emit((1 << 20) | (0x18 << 15) | (7 << 10) | (6 << 5) | 10, 10, 63)
addi(11, 10, 1)
addi(10, 0, 99)
emit((2 << 20) | (7 << 10) | (6 << 5) | 10, 10, 7)
emit((0x19 << 26) | (2 << 10) | (10 << 5) | 7)
emit((0xa << 26) | (6 << 22) | (1 << 5) | 6)
emit((2 << 20) | (7 << 10) | (6 << 5) | 10, 10, 7)
emit((0x18 << 26) | (2 << 10) | (7 << 5) | 6)
emit((0xa << 26) | (6 << 22) | (1 << 5) | 6)
addi(30, 0, 1)
emit(0x50000000)  # b 0
(out / 'program.hex').write_text(''.join(f'{x:08x}\n' for x in code))
(out / 'expected.hex').write_text(''.join(f'{pc:08x}{rd:02x}{val:08x}\n' for pc, rd, val in expected))
(out / 'counts.vh').write_text(f'`define COMMITS {len(expected)}\n`define STORES {stores}\n`define WORDS {len(code)}\n')
print(f'Generated {len(code)} instructions, {len(expected)} commits, {stores} stores')
