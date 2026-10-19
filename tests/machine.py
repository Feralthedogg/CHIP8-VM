"""Execute the built Windows binary's real x86-64 code without a Windows GUI."""

import os
from pathlib import Path
import shlex
import struct
import subprocess

import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
from unicorn.x86_const import (
    UC_X86_REG_RAX, UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8,
    UC_X86_REG_R9, UC_X86_REG_R10, UC_X86_REG_R11, UC_X86_REG_RIP,
    UC_X86_REG_RSP,
)

ROOT = Path(__file__).resolve().parents[1]
OFF_V = 4096
OFF_I = 4112
OFF_PC = 4114
OFF_GFX = 4149
OFF_DELAY = 6197
OFF_SOUND = 6198
OFF_KEYS = 6199
OFF_DIRTY = 6215
OFF_WAITFLAG = 6216
CHIP8_SIZE = 6219


class Binary:
    def __init__(self, path=None):
        self.path = Path(path or os.environ.get("CHIP8_EXE", ROOT / "chip8.exe"))
        pe = pefile.PE(str(self.path))
        self.base = pe.OPTIONAL_HEADER.ImageBase
        self.size = (pe.OPTIONAL_HEADER.SizeOfImage + 4095) & ~4095
        self.image = pe.get_memory_mapped_image()
        nm = shlex.split(os.environ.get("NM", "x86_64-w64-mingw32-nm"))
        listing = subprocess.check_output(nm + ["-g", str(self.path)], text=True)
        self.symbols = {}
        for line in listing.splitlines():
            parts = line.split()
            if len(parts) == 3:
                self.symbols[parts[2]] = int(parts[0], 16)


class Machine:
    STACK = 0x70000000
    DATA = 0x71000000
    STOP = 0x72000000

    def __init__(self, binary):
        self.binary = binary
        self.uc = Uc(UC_ARCH_X86, UC_MODE_64)
        self.uc.mem_map(binary.base, binary.size)
        self.uc.mem_write(binary.base, binary.image)
        self.uc.mem_map(self.STACK, 0x200000)
        self.uc.mem_map(self.DATA, 0x10000)
        self.uc.mem_map(self.STOP, 0x1000)
        self.state = binary.symbols["chip8_state"]
        self.api_calls = []
        self._hooks = []
        self._cpu_fraction = 0
        self.call("chip8_init")

    def call(self, name, *args):
        sp = self.STACK + 0x100000 - 8
        self.uc.reg_write(UC_X86_REG_RSP, sp)
        self.uc.mem_write(sp, struct.pack("<Q", self.STOP))
        for reg, value in zip((UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9), args):
            self.uc.reg_write(reg, value)
        self.uc.emu_start(self.binary.symbols[name], self.STOP, count=1_000_000)
        if self.uc.reg_read(UC_X86_REG_RIP) != self.STOP:
            raise RuntimeError(f"{name} exceeded the x86 instruction budget")
        if self.uc.reg_read(UC_X86_REG_RSP) != sp + 8:
            raise AssertionError(f"{name} did not restore the stack pointer")
        return self.uc.reg_read(UC_X86_REG_RAX)

    def stub_api(self, name, result=0):
        """Model a Win64 callee that consumes its home space and volatile registers."""
        def stub(uc, address, size, user_data):
            sp = uc.reg_read(UC_X86_REG_RSP)
            if (sp + 8) % 16:
                raise AssertionError(f"Unaligned stack on entry to {name}")
            args = tuple(uc.reg_read(reg) for reg in (
                UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8, UC_X86_REG_R9
            ))
            self.api_calls.append((name, args))
            target = struct.unpack("<Q", uc.mem_read(sp, 8))[0]
            uc.mem_write(sp + 8, b"\xCC" * 32)
            for reg in (UC_X86_REG_RCX, UC_X86_REG_RDX, UC_X86_REG_R8,
                        UC_X86_REG_R9, UC_X86_REG_R10, UC_X86_REG_R11):
                uc.reg_write(reg, 0xDEADBEEF)
            uc.reg_write(UC_X86_REG_RAX, result)
            uc.reg_write(UC_X86_REG_RSP, sp + 8)
            uc.reg_write(UC_X86_REG_RIP, target)

        address = self.binary.symbols[name]
        self._hooks.append(self.uc.hook_add(UC_HOOK_CODE, stub, begin=address, end=address))

    def read(self, offset, size=1):
        return bytes(self.uc.mem_read(self.state + offset, size))

    def write(self, offset, data):
        self.uc.mem_write(self.state + offset, bytes(data))

    def word(self, offset):
        return struct.unpack("<H", self.read(offset, 2))[0]

    def set_word(self, offset, value):
        self.write(offset, struct.pack("<H", value))

    def opcode(self, value):
        self.write(0x200, value.to_bytes(2, "big"))
        self.set_word(OFF_PC, 0x200)

    def load(self, data):
        if len(data) > 4096 - 0x200:
            raise ValueError("ROM exceeds the 3584-byte program area")
        self.write(0x200, data)

    def frame(self):
        # Deterministic 700 IPS / 60 Hz scheduling for ROM tests, without Win32.
        self._cpu_fraction += 700
        steps, self._cpu_fraction = divmod(self._cpu_fraction, 60)
        for _ in range(steps):
            self.call("chip8_step")
        self.call("chip8_tick_timers")

    def framebuffer(self):
        return self.read(OFF_GFX, 64 * 32)

    def run_until_loop(self, limit=20_000):
        for step in range(limit):
            pc = self.word(OFF_PC)
            opcode = int.from_bytes(self.read(pc, 2), "big")
            if opcode == (0x1000 | pc):
                return step
            self.call("chip8_step")
        raise AssertionError("ROM did not reach its terminal self-jump")
