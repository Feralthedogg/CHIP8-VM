import struct
import unittest

from unicorn.x86_const import (
    UC_X86_REG_RBP, UC_X86_REG_RBX, UC_X86_REG_RSI, UC_X86_REG_RDI,
    UC_X86_REG_R12, UC_X86_REG_R13, UC_X86_REG_R14, UC_X86_REG_R15,
)

from machine import (
    Binary, Machine, CHIP8_SIZE, OFF_V, OFF_I, OFF_PC, OFF_DELAY,
    OFF_WAITFLAG,
)


class CoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Binary()

    def setUp(self):
        self.vm = Machine(self.binary)

    def test_random_targets_each_register_and_applies_mask(self):
        seed = 1
        for reg in range(16):
            for mask in (0, 0x0F, 0x80, 0xFF):
                with self.subTest(reg=reg, mask=mask):
                    before = bytes(range(16))
                    self.vm.write(OFF_V, before)
                    self.vm.opcode(0xC000 | reg << 8 | mask)
                    seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
                    self.vm.call("chip8_step")
                    expected = bytearray(before)
                    expected[reg] = ((seed >> 16) & 0xFF) & mask
                    self.assertEqual(self.vm.read(OFF_V, 16), expected)
                    self.assertEqual(self.vm.word(OFF_PC), 0x202)

    def test_bcd_wraps_each_address_and_preserves_registers(self):
        for addr in (0x300, 0xFFD, 0xFFE, 0xFFF):
            for value in (0, 9, 10, 99, 100, 123, 255):
                with self.subTest(addr=hex(addr), value=value):
                    self.vm.opcode(0xF133)
                    self.vm.set_word(OFF_I, addr)
                    registers = bytearray(range(16))
                    registers[1] = value
                    self.vm.write(OFF_V, registers)
                    before = self.vm.read(0, CHIP8_SIZE)
                    self.vm.call("chip8_step")
                    expected = bytearray(before)
                    for digit, displacement in zip((value // 100, value // 10 % 10, value % 10), range(3)):
                        expected[(addr + displacement) & 0xFFF] = digit
                    expected[OFF_PC:OFF_PC + 2] = b"\x02\x02"
                    self.assertEqual(self.vm.read(0, CHIP8_SIZE), expected)

    def test_audio_callback_preserves_nonvolatile_registers_and_requeues_header(self):
        self.vm.call("cdp1802_init")
        symbols = self.binary.symbols
        self.vm.call("cdp1802_load", symbols["cdp1802_beep_rom"], 0,
                     symbols["cdp1802_beep_rom_end"] - symbols["cdp1802_beep_rom"])
        self.vm.stub_api("waveOutWrite")
        handle = 0x1234
        self.vm.uc.mem_write(symbols["chip8_hWaveOut"], struct.pack("<Q", handle))
        nonvolatile = (UC_X86_REG_RBP, UC_X86_REG_RBX, UC_X86_REG_RSI, UC_X86_REG_RDI,
                       UC_X86_REG_R12, UC_X86_REG_R13, UC_X86_REG_R14, UC_X86_REG_R15)
        for samples in (0, 160):
            with self.subTest(samples=samples):
                header, pcm = self.vm.DATA, self.vm.DATA + 0x100
                self.vm.uc.mem_write(header, struct.pack("<QI", pcm, samples) + b"\x00" * 36)
                self.vm.uc.mem_write(pcm, b"\x55" * 160)
                expected = {reg: 0x1234567800000000 + index for index, reg in enumerate(nonvolatile)}
                for reg, value in expected.items():
                    self.vm.uc.reg_write(reg, value)
                self.assertEqual(self.vm.call("WndProc", 0, 0x3BD, handle, header), 0)
                for reg, value in expected.items():
                    self.assertEqual(self.vm.uc.reg_read(reg), value, f"Register {reg} changed")
                api, args = self.vm.api_calls[-1]
                self.assertEqual(api, "waveOutWrite")
                self.assertEqual(args[:3], (handle, header, 48))
                if samples:
                    self.assertEqual(bytes(self.vm.uc.mem_read(pcm, samples)), b"\x80" * samples)

    def test_audio_callback_ignores_null_header(self):
        self.assertEqual(self.vm.call("WndProc", 0, 0x3BD, 0, 0), 0)
        self.assertEqual(self.vm.api_calls, [])

    def test_key_wait_requires_matching_release_and_keeps_timers_running(self):
        self.vm.opcode(0xF10A)
        self.vm.write(OFF_DELAY, [2, 2])
        self.vm.call("chip8_step")
        self.assertEqual(self.vm.read(OFF_WAITFLAG), b"\x01")
        self.vm.call("chip8_set_key", 5, 1)
        self.assertEqual(self.vm.read(OFF_WAITFLAG), b"\x02")
        self.vm.call("chip8_step")
        self.assertEqual(self.vm.word(OFF_PC), 0x202)
        self.vm.call("chip8_tick_timers")
        self.assertEqual(self.vm.read(OFF_DELAY, 2), b"\x01\x01")
        self.vm.call("chip8_set_key", 4, 0)
        self.assertEqual(self.vm.read(OFF_WAITFLAG), b"\x02")
        self.vm.call("chip8_set_key", 5, 0)
        self.assertEqual(self.vm.read(OFF_WAITFLAG), b"\x00")
        self.assertEqual(self.vm.read(OFF_V + 1), b"\x05")

    def test_key_wait_with_key_already_held(self):
        self.vm.call("chip8_set_key", 0xA, 1)
        self.vm.opcode(0xF30A)
        self.vm.call("chip8_step")
        self.assertEqual(self.vm.read(OFF_WAITFLAG), b"\x02")
        self.vm.call("chip8_set_key", 0xA, 0)
        self.assertEqual(self.vm.read(OFF_V + 3), b"\x0A")
        self.assertEqual(self.vm.read(OFF_WAITFLAG), b"\x00")


if __name__ == "__main__":
    unittest.main()
