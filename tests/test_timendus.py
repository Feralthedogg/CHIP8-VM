"""ROM-level checks against Timendus' independent tests and reference screens."""

import json
from pathlib import Path
import unittest

from PIL import Image

from fixtures import fixture, MANIFEST
from machine import Binary, Machine, OFF_WAITFLAG

REPORTS = Path(__file__).resolve().parent / "reports"


class TimendusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = Binary()
        cls.results = {"upstream_commit": MANIFEST["commit"], "checks": {}}
        REPORTS.mkdir(parents=True, exist_ok=True)

    @classmethod
    def tearDownClass(cls):
        (REPORTS / "timendus.json").write_text(json.dumps(cls.results, indent=2) + "\n")

    def load(self, name):
        vm = Machine(self.binary)
        vm.load(fixture(f"bin/{name}.ch8").read_bytes())
        return vm

    def snapshot(self, name, vm):
        frame = vm.framebuffer()
        image = Image.frombytes("L", (64, 32), bytes(pixel * 255 for pixel in frame))
        image.resize((768, 384), Image.Resampling.NEAREST).save(REPORTS / f"{name}.png")
        return frame

    def assert_reference(self, name, vm, reference, ignore_version=False):
        actual = self.snapshot(name, vm)
        with Image.open(fixture(f"pictures/{reference}.png")) as source:
            image = source.convert("RGB").resize((64, 32), Image.Resampling.NEAREST)
            colors = list(image.get_flattened_data())
        foreground = max(set(colors), key=sum)
        expected = bytes(int(color == foreground) for color in colors)
        differences = [index for index, (a, b) in enumerate(zip(actual, expected))
                       if a != b and not (ignore_version and index % 64 >= 48 and index // 64 >= 26)]
        self.results["checks"][name] = {
            "status": "pass" if not differences else "fail",
            "different_pixels": len(differences),
            "version_label_excluded": ignore_version,
        }
        self.assertEqual(differences, [], f"Reference screen mismatch; see {REPORTS / (name + '.png')}")

    def test_splash(self):
        vm = self.load("1-chip8-logo")
        vm.run_until_loop()
        self.assert_reference("splash", vm, "chip-8-logo")

    def test_ibm_logo(self):
        vm = self.load("2-ibm-logo")
        vm.run_until_loop()
        self.assert_reference("ibm-logo", vm, "ibm-logo")

    def test_corax_opcodes(self):
        vm = self.load("3-corax+")
        vm.run_until_loop()
        self.assert_reference("corax", vm, "corax+", ignore_version=True)

    def test_arithmetic_flags(self):
        vm = self.load("4-flags")
        vm.run_until_loop()
        self.assert_reference("flags", vm, "flags", ignore_version=True)

    def test_quirks_records_existing_profile(self):
        vm = self.load("5-quirks")
        vm.write(0x1FF, [1])  # Select CHIP-8 without driving the menu.
        self.run_until_wait(vm, 1200)
        frame = self.snapshot("quirks", vm)
        names = ("vf-reset", "memory-increment", "display-wait", "clipping", "shifting", "jumping")
        observed = {}
        for name, y in zip(names, (2, 7, 12, 17, 22, 27)):
            pixels = tuple(tuple(frame[(y + row) * 64 + 59 + col] for col in range(3))
                           for row in range(3))
            if pixels == ((1, 0, 1), (1, 1, 0), (1, 0, 0)):
                observed[name] = "pass"
            elif pixels == ((1, 0, 1), (0, 1, 0), (1, 0, 1)):
                observed[name] = "known difference"
            else:
                self.fail(f"Unrecognized quirks result for {name}: {pixels}")
        self.results["checks"]["quirks"] = observed
        # These are compatibility limits, not a claim of complete VIP accuracy.
        self.assertEqual(observed, {
            "vf-reset": "known difference", "memory-increment": "pass",
            "display-wait": "known difference", "clipping": "known difference",
            "shifting": "pass", "jumping": "pass",
        })

    def run_until_wait(self, vm, limit=120):
        for _ in range(limit):
            vm.frame()
            if vm.read(OFF_WAITFLAG) != b"\x00":
                return
        self.fail("ROM did not reach Fx0A within its frame budget")

    def test_keypad_wait_for_release(self):
        vm = self.load("6-keypad")
        vm.write(0x1FF, [3])  # Select the Fx0A scenario.
        self.run_until_wait(vm)
        for _ in range(6):
            vm.frame()
        vm.call("chip8_set_key", 0xA, 1)
        vm.frame()
        self.assertEqual(vm.read(OFF_WAITFLAG), b"\x02")
        vm.call("chip8_set_key", 0xA, 0)
        self.run_until_wait(vm)
        self.assert_reference("keypad", vm, "keypad-getkey")

    def test_beep_timer_gate_and_pcm(self):
        vm = self.load("7-beep")
        symbols = self.binary.symbols
        vm.call("cdp1802_init")
        vm.call("cdp1802_load", symbols["cdp1802_beep_rom"], 0,
                symbols["cdp1802_beep_rom_end"] - symbols["cdp1802_beep_rom"])
        lengths = []
        sounding = 0
        samples = []
        for _ in range(600):
            vm.frame()
            gate = vm.uc.mem_read(symbols["cdp1802_gate"], 1)[0]
            if gate:
                sounding += 1
                if not samples:
                    samples = [vm.call("cdp1802_audio_sample", 1) for _ in range(160)]
            elif sounding:
                lengths.append(sounding)
                sounding = 0
                if len(lengths) == 9:
                    break
        self.assertEqual(len(lengths), 9)
        self.assertEqual([length > 20 for length in lengths],
                         [False, False, False, True, True, True, False, False, False])
        self.assertTrue(all(9 <= length <= 12 or 29 <= length <= 32 for length in lengths))
        self.assertGreater(len(set(samples)), 1)
        self.assertTrue(all(0 <= sample <= 255 for sample in samples))
        self.snapshot("beep", vm)
        self.results["checks"]["beep"] = {
            "status": "pass", "sound_pulse_frames": lengths,
            "pcm_range": [min(samples), max(samples)],
            "scope": "timer, gate, generated PCM; Windows audio device not exercised",
        }


if __name__ == "__main__":
    unittest.main()
