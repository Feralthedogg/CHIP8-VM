# CHIP-8 VM — x86-64 / GAS (AT&T) / Windows (MinGW-w64)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A **CHIP-8 virtual machine** implemented in pure **x86-64 assembly (AT&T syntax)** for Windows.

On startup it initializes the CHIP-8 state, opens a Win32 window, sets up a GDI-based framebuffer, and then runs the ROM in a timer-driven loop while rendering a scaled 64×32 display.

This VM deliberately follows **“classic” CHIP-8 quirks**, not the later “modern” variants.  
Some newer ROMs that rely on modern semantics (e.g. `Fx55/Fx65` not changing `I`) may misbehave.

Audio is provided by a tiny **CDP1802 core** that drives a **COSMAC VIP–style CA555 beeper**: the 1802’s `Q` bit gates a ≈1 kHz square-wave tone derived from the VIP’s 555 astable RC network, passed through a simple speaker/RC model and rendered to a 1-second in-memory WAV that is looped with `PlaySoundA`.

---

## Build & Run

### Using `make` (recommended)

```bash
# In the project directory (chip8.asm, cdp1802.asm, Makefile)
make
````

This runs roughly:

```bash
x86_64-w64-mingw32-gcc -x assembler -c chip8.asm -o chip8.o
x86_64-w64-mingw32-gcc -x assembler -c cdp1802.asm -o cdp1802.o
x86_64-w64-mingw32-gcc chip8.o cdp1802.o -o chip8.exe -lgdi32 -luser32 -lkernel32 -lwinmm
```

### Direct compilation

```bash
x86_64-w64-mingw32-gcc -x assembler -c .\chip8.asm   -o .\chip8.o
x86_64-w64-mingw32-gcc -x assembler -c .\cdp1802.asm -o .\cdp1802.o
x86_64-w64-mingw32-gcc .\chip8.o .\cdp1802.o -o .\chip8.exe ^
    -lgdi32 -luser32 -lkernel32 -lwinmm
```

### Run

```bash
.\chip8.exe <romfile>
```

Example:

```bash
.\chip8.exe ROMS/test0.ch8
```

* If no ROM path is given, it prints usage and exits.
* On success:

  * Prints `Loaded ROM: <filename>`
  * Dumps the first 4 bytes of `memory[0x200..0x203]`
  * Prints a small `After init+load` line
  * Registers a Win32 window class and opens the main window
  * Starts the timer-driven CHIP-8 loop

---

## Display & controls

### Video

* Logical resolution: **64 × 32** (standard CHIP-8)
* Pixel format: **monochrome** (0/1 per pixel)
* Scale factor: `SCALE = 10` → visible area ≈ 640×320 (plus window chrome)

Rendering pipeline:

* The **window class background brush** (`hBrushOff`, black) clears the client area on `WM_PAINT`.
* `chip8_render_window` iterates the 64×32 framebuffer and draws **only “on” pixels** with `FillRect()` using `hBrushOn` (white).
* A **dirty flag** (`OFF_DIRTY`) is set by `00E0` and `Dxyn`.
* The timer only invalidates the window when this flag is set → no unnecessary GDI work.

### Keyboard mapping

CHIP-8 keypad:

```text
1  2  3  C
4  5  6  D
7  8  9  E
A  0  B  F
```

Mapped to PC keys:

```text
1  2  3  4
Q  W  E  R
A  S  D  F
Z  X  C  V
```

| CHIP-8 | PC key |
| ------ | ------ |
| `1`    | `1`    |
| `2`    | `2`    |
| `3`    | `3`    |
| `C`    | `4`    |
| `4`    | `Q`    |
| `5`    | `W`    |
| `6`    | `E`    |
| `D`    | `R`    |
| `7`    | `A`    |
| `8`    | `S`    |
| `9`    | `D`    |
| `E`    | `F`    |
| `A`    | `Z`    |
| `0`    | `X`    |
| `B`    | `C`    |
| `F`    | `V`    |

* **ESC** – closes the emulator (posts `WM_QUIT`).

---

## Timing & main loop

The VM uses a **Win32 timer**:

```c
SetTimer(hWndMain, TIMER_ID_STEP, TIMER_INTERVAL_MS, NULL);
```

* `TIMER_INTERVAL_MS = 16` → ~62.5 Hz tick.

On each `WM_TIMER` (`WndProc_do_timer`):

1. Run `chip8_step` a small fixed number of times (currently **8** steps per tick).
2. Call `chip8_tick_timers` to update delay/sound timers at ~60 Hz.
3. If `OFF_DIRTY != 0`, call `InvalidateRect(hWndMain, NULL, TRUE)` to trigger a repaint.

So the default CPU rate is roughly:

* **~500 instructions per second** (8 steps × ~62.5 ticks).

You can tune speed by editing:

```asm
WndProc_do_timer:
    movl  $8, %ecx          # steps per tick (raise for faster CPU)
```

The main thread runs a standard `GetMessage` loop so the window stays responsive.

---

## Memory layout

All CHIP-8 state lives in a single `.bss` block (`chip8_state`) with fixed offsets:

```text
OFF_MEMORY    = 0           ; 4 KiB memory (0x000–0xFFF)
OFF_V         = +4096       ; V0..VF (16 × 8-bit)
OFF_I         = +16         ; 16-bit I
OFF_PC        = +2          ; 16-bit PC
OFF_SP        = +2          ; 8-bit SP (0..15)
OFF_STACK     = +1          ; 16 × 16-bit call stack
OFF_GFX       = +16*2       ; 64×32 framebuffer (2048 bytes)
OFF_DELAY     = +64*32      ; delay timer (8-bit)
OFF_SOUND     = +1          ; sound timer (8-bit)
OFF_KEYS      = +1          ; 16-key state table (bytes: 0/1)
OFF_DIRTY     = +16         ; display dirty flag (1 = needs repaint)
OFF_WAITFLAG  = +1          ; Fx0A wait flag (1 = waiting for key)
OFF_WAITREG   = +1          ; Fx0A target V-register index (0..15)
CHIP8_SIZE    = OFF_WAITREG + 1
```

`chip8_init`:

* Clears the whole struct (`CHIP8_SIZE` bytes).
* Sets `PC = 0x200`.
* Copies font sprites (`chip8_font`) into `memory[0x50..]`.
* Seeds the CHIP-8 LCG RNG (`chip8_rng_state`).
* Calls `chip8_build_beep_pcm` to build a **1-second CDP1802-driven beep** into `chip8_beep_pcm`.

ROM loading (`load_rom`):

* Uses `CreateFileA` / `ReadFile` into `memory[0x200..]` up to `0xFFF`.
* Dumps `memory[0x200..0x203]` to the console for sanity.

---

## Instruction set & **classic quirks**

The interpreter implements the standard CHIP-8 instruction set:

* Flow/control:

  * `00E0` — CLS
  * `00EE` — RET
  * `1nnn` — JP nnn
  * `2nnn` — CALL nnn
  * `Bnnn` — JP V0, nnn
* Conditionals:

  * `3xkk` — SE Vx, kk
  * `4xkk` — SNE Vx, kk
  * `5xy0` — SE Vx, Vy
  * `9xy0` — SNE Vx, Vy
  * `Ex9E` — SKP Vx
  * `ExA1` — SKNP Vx
* Arithmetic / logic:

  * `6xkk`, `7xkk`
  * `8xy0`..`8xy7`, `8xyE`
* Random:

  * `Cxkk` — RND Vx, kk (LCG-based `rng_next_byte`)
* Drawing:

  * `Dxyn` — sprite draw, XOR, collision sets VF, wraps at 64×32
* Timers / memory:

  * `Fx07`, `Fx0A`
  * `Fx15`, `Fx18`
  * `Fx1E`, `Fx29`, `Fx33`
  * `Fx55`, `Fx65`

### Classic behavior (deliberate)

This core is intentionally **classic-style**, not “modern”:

* **Shift ops `8xy6`, `8xyE`**

  * Use **Vy** as the source.
  * `VF` gets the LSB/MSB of **Vy** before the shift.
  * The shifted result is written to **Vx**.

* **`Bnnn`**

  * Always jumps to `(V0 + nnn) & 0x0FFF`.

* **`Fx1E`**

  * `I = (I + Vx) & 0x0FFF`.
  * `VF` is **not** touched.

* **`Fx55`, `Fx65`**

  * Implement the **classic quirk**:
    After copying `V0..Vx`, `I` becomes `(I + X + 1) & 0x0FFF`.
  * Many modern ROMs assume **“I unchanged”** semantics; those may not run correctly on this core.

If you want to support modern ROM suites, you’d typically add a “mode flag” and branch inside `Fx55/Fx65` / shift ops to provide both behaviors. This implementation keeps things clean and explicitly classic.

### Fx0A — non-blocking “wait for key”

`Fx0A` is implemented with true “wait for key” semantics but without freezing the GUI:

* On executing `Fx0A`:

  1. It first scans the key table.

     * If **any key is already pressed**, its index is written into `Vx` and execution continues.
  2. If **no key is pressed**:

     * `OFF_WAITFLAG` is set to `1`.
     * `OFF_WAITREG` stores `x` (target register index).
     * `chip8_step` returns without executing further opcodes.

* On entry, `chip8_step` checks `OFF_WAITFLAG`:

  * If it is non-zero, `chip8_step` immediately returns (no fetch/execute).
    Timers and the Win32 message loop continue to run, so the window stays responsive.

* On key press (`WM_KEYDOWN` → `chip8_set_key`):

  * The key index is updated in `OFF_KEYS`.
  * If `OFF_WAITFLAG != 0` and this is a **press**, then:

    * `V[OFF_WAITREG] = key_index`
    * `OFF_WAITFLAG = 0` → normal execution resumes on the next step.

---

## Audio — CDP1802-driven COSMAC VIP 555 beep

Sound is driven by a small **CDP1802 core** (`cdp1802.asm`) and a simple model of the COSMAC VIP beeper hardware.

### Minimal CDP1802 core

The 1802 core keeps a compact state block:

* General registers `R0..R15` (16×16-bit)
* `D`, `DF`, `P`, `X`, `Q`, `IE`, `T`
* 64 KiB of memory (`cdp1802_mem`)
* A 64-bit **machine cycle counter** (`cdp1802_mcycles`), where:

  * Most instructions add **2 cycles**
  * Long branches (`LBR`) add **3 cycles**

Implemented instructions (enough for a simple tone generator ROM):

* `00` — `IDL` : idle, no state change
* `7A` — `REQ` : `Q = 0`
* `7B` — `SEQ` : `Q = 1`
* `30` — `BR`  : short unconditional branch
* `31` — `BQ`  : branch if `Q == 1`
* `39` — `BNQ` : branch if `Q == 0`
* `C0` — `LBR` : long unconditional branch (16-bit address)
* `F8` — `LDI` : `D = imm`

Everything else is treated as a 1-byte NOP (2 machine cycles).

A tiny **test beep ROM** (`cdp1802_beep_rom`) just toggles the Q line in a loop:

```asm
0000: 7A          ; REQ        -> Q = 0
0001: C0 00 04    ; LBR 0004   -> jump to 0004
0004: 7B          ; SEQ        -> Q = 1
0005: C0 00 00    ; LBR 0000   -> jump to 0000
```

### Audio model

`unsigned char cdp1802_audio_sample(unsigned int steps_per_sample);`

For each audio sample:

1. **Run the 1802** for `steps_per_sample` instruction steps (`cdp1802_step`).

2. **Detect Q rising edge**:

   * If Q goes `0 → 1`, the internal tone **phase accumulator is reset** – this approximates a 555 being (re)triggered.

3. **Generate a CA555-style square wave** when Q = 1:

   * The oscillator is a 32-bit phase accumulator:

     ```c
     phase += tone_step;
     saw = phase >> 22;  // 10-bit saw 0..1023
     ```

   * `tone_step` is precomputed from the **actual COSMAC VIP 555 astable RC network**:

     * `R1 = 100 kΩ, R2 = 100 kΩ, C = 0.0047 µF`
     * `f ≈ 1.44 / ((R1 + 2*R2) * C) ≈ 1.02 kHz`
     * `tone_step ≈ 2^32 * f / sample_rate` (see `cdp1802.asm` for the exact constant).

   * A threshold of about **2/3 of the saw** (≈682 out of 1023) yields an **asymmetric duty cycle (~66.7%)**, matching a typical 555 astable:

     ```c
     if (saw < threshold)  // ~2/3
         raw = high_level; // e.g. ~3.3V equivalent
     else
         raw = 0;
     ```

   * The “high” level is chosen below full-scale (e.g. equivalent of 3.3 V on a 5 V system → ≈168 on an 8-bit 0..255 scale), so the waveform doesn’t slam rail-to-rail.

4. When Q = 0:

   * The generator doesn’t just hard-mute to 0;
   * It uses a slowly adapting **DC offset tracker** as the “raw” value, approximating AC coupling into a small speaker.

5. **2-stage low-pass filtering**:

   Two identical 1st-order IIR filters are cascaded:

   ```c
   // stage 1
   y1 += (x  - y1) >> 3;  // ≈ 1/8

   // stage 2
   y2 += (y1 - y2) >> 3;  // ≈ 1/8
   ```

   This roughly mimics the combined response of a simple RC output network + the mechanical smoothing of a cheap speaker.

6. **Very slow DC offset adaptation**:

   ```c
   dc += (sample - dc) >> 8; // ≈ 1/256 per sample
   ```

   This acts like a crude **AC coupling capacitor** / bias drift, keeping the long-term average near mid-scale instead of building up offset.

7. The final value is **clamped to 0..255** and returned as an unsigned 8-bit PCM sample (`AL` / `EAX`).

### Beep PCM generation

`chip8_build_beep_pcm` wires everything together:

* `cdp1802_init()`:

  * Zeros the 1802 state, initializes LPF / DC offset around 128, resets the phase accumulator, sets the default `tone_step`, seeds the RNG, resets the machine cycle counter and Q-previous state.

* `cdp1802_load(cdp1802_beep_rom, 0x0000, CDP1802_BEEP_ROM_SIZE)`:

  * Loads the small 8-byte beep ROM at address 0.

* Renders **8000 samples (1 second @ 8 kHz)** into `chip8_beep_pcm`:

  ```c
  for (i = 0; i < 8000; ++i)
      pcm[i] = cdp1802_audio_sample(1); // 1 CPU step per audio sample
  ```

The final layout in memory is:

* `chip8_beep_wav` — A RIFF/WAVE header for **8-bit mono, 8 kHz PCM**.
* `chip8_beep_pcm` — 8000 bytes of CDP1802-generated audio.

Together, `[chip8_beep_wav .. chip8_beep_wav + 44 + 8000)` form a valid in-memory WAV image.

### Integration with the CHIP-8 sound timer

* `chip8_tick_timers` runs at ~60 Hz:

  * If `delay > 0`, decrements `delay`.
  * If `sound > 0`, decrements `sound`.

* Sound gating:

  * If `OFF_SOUND > 0` → `chip8_start_beep()`:

    ```c
    PlaySoundA(chip8_beep_wav, NULL,
               SND_ASYNC | SND_MEMORY | SND_NODEFAULT | SND_LOOP);
    ```

    guarded by `chip8_sound_on_flag` so `PlaySoundA` is not spammed every tick.

  * If `OFF_SOUND == 0` → `chip8_stop_beep()`:

    ```c
    PlaySoundA(NULL, NULL, 0);  // stop current sound
    ```

* `WndProc_do_destroy` also calls `chip8_stop_beep()` before quitting, to make sure the looped beep is killed when the window closes.

All audio work is done on the main thread, using a **pre-rendered 1-second buffer** looped via `PlaySoundA`; there are no extra audio threads.

---

## Error handling & debugging

### ROM loading

If the ROM fails to open:

```text
Failed to open ROM file
```

Common checks:

* Path / filename correct?
* Working directory where you expect?
* Permissions OK?

### Console debug output

A typical startup:

```text
Loaded ROM: ROMS/test0.ch8
ROM[0x200..0x203] = 00 E0 60 04
After init+load
RegisterClassExA = 49967
hWndMain = 00000000007D09E4
```

This confirms:

* ROM loaded at `0x200`.
* First opcodes look sane.
* Window class registration succeeded.
* A non-zero window handle exists.

If the window opens but you only see a black screen:

* Make sure your ROM actually draws (`Dxyn`) and/or clears (`00E0`) the screen.
* Confirm `PC` starts at `0x200` and the first opcodes execute.
* Check that the timer is running (task manager CPU usage not exactly zero).
* Verify that drawing or `CLS` is setting `OFF_DIRTY` so repaint is triggered.

If a modern multi-test ROM behaves strangely or exits immediately, check whether it relies on **modern quirks** (e.g. `Fx55/Fx65` not advancing `I`). Those are **not** supported here by design.

---

## Implementation notes (dev-oriented)

* Language: **x86-64 assembly**, GAS (AT&T syntax)
* Target: **Windows / MinGW-w64**

### External APIs

* `user32.dll` – window class, `CreateWindowExA`, message loop, timers, etc.
* `gdi32.dll` – `FillRect`, `CreateSolidBrush`, `DeleteObject`.
* `kernel32.dll` – file I/O (`CreateFileA`, `ReadFile`, `CloseHandle`).
* `winmm.dll` – `PlaySoundA`.
* `printf` from the MinGW runtime for debug logging.

### Core routines

* `chip8_init` – zero/initialize CHIP-8 state, font, RNG, build beep PCM.
* `chip8_step` – single-opcode interpreter with classic quirks and Fx0A wait logic.
* `chip8_tick_timers` – 60 Hz timers + sound on/off.
* `chip8_set_key` – update OFF_KEYS and wake Fx0A waits.
* `chip8_render_window` – render framebuffer to an HDC and clear DIRTY.
* `load_rom` – WinAPI ROM loading and hex dump.
* `WndProc` – full Win32 window proc (paint, timer, keyboard, destroy).

CDP1802 side:

* `cdp1802_init`, `cdp1802_load`, `cdp1802_step`, `cdp1802_get_q`
* `cdp1802_audio_sample` + helper state (tone phase, filters, DC offset, machine cycle counter)
* `cdp1802_beep_rom` – minimal ROM that toggles Q for the VIP-style beep

### Conventions

* `%rbx` usually holds the base pointer to `chip8_state`.
* CHIP-8 memory is accessed as `OFF_MEMORY(%rbx, index, 1)` with indices masked to 0x0FFF.
* `chip8_step` keeps PC normalized to 12 bits at all times.
* Non-volatile registers (`rbx`, `rbp`, `rsi`, `rdi`, `r12`–`r15`) are preserved according to the Microsoft x64 ABI; all WinAPI calls have 32 bytes of shadow space reserved.

---

## Example session

```text
PS> .\chip8.exe ROMS/test0.ch8
Loaded ROM: ROMS/test0.ch8
ROM[0x200..0x203] = 00 E0 60 04
After init+load
RegisterClassExA = 49967
hWndMain = 00000000007D09E4
```

A window appears with the 64×32 display scaled up.

* Use `1 2 3 4 / Q W E R / A S D F / Z X C V` to interact.
* When a ROM drives the sound timer, you’ll hear the CDP1802-generated VIP-style beep.
* Press **ESC** to exit.

---

## License

This project is released under the [MIT License](./LICENSE).