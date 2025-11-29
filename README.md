# CHIP-8 VM — x86-64 / GAS (AT&T) / Windows (MinGW-w64)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

A **CHIP-8 virtual machine** implemented in pure **x86-64 assembly (AT&T syntax)** for Windows.

On startup it initializes the CHIP-8 state, opens a Win32 window, sets up a GDI-based framebuffer, and then runs the ROM in a timer-driven loop while rendering a scaled 64×32 display.  
The core is “classic CHIP-8”-oriented and includes a non-blocking, event-driven implementation of `Fx0A` (wait for key).

---

## Build & Run

### Using `make` (recommended)

```bash
# In the project directory (chip8.asm, Makefile)
make
````

This runs roughly:

```bash
x86_64-w64-mingw32-gcc -x assembler -c chip8.asm -o chip8.o
x86_64-w64-mingw32-gcc chip8.o -o chip8.exe -lgdi32 -luser32 -lkernel32
```

### Direct compilation

```bash
x86_64-w64-mingw32-gcc -x assembler -c .\chip8.asm -o .\chip8.o
x86_64-w64-mingw32-gcc .\chip8.o -o .\chip8.exe -lgdi32 -luser32 -lkernel32
```

### Run

```bash
.\chip8.exe <romfile>
```

Example:

```bash
.\chip8.exe ROMS/test0.ch8
```

* If no ROM path is given: prints usage and exits.
* On success:

  * Prints: `Loaded ROM: <filename>`
  * Dumps first 4 bytes of `memory[0x200..0x203]`.
  * Prints a small `After init+load` debug line.
* Then opens a Win32 window and starts the main message loop.

---

## Display & controls

### Video

* Logical resolution: **64 × 32** (CHIP-8 standard).
* Pixel format: **monochrome** (0 or 1 per pixel).
* Scale factor: `SCALE = 10` → visible area ≈ 640×320 (plus window chrome).

Rendering pipeline:

* The **window class background brush** (`hBrushOff`, black) clears the client area on `WM_PAINT`.
* `chip8_render_window` iterates the 64×32 framebuffer and draws **only “on” pixels** with `FillRect()` using `hBrushOn` (white).
* A **dirty flag** (`OFF_DIRTY`) is set by drawing opcodes (`Dxyn`) and `CLS (00E0)`, and cleared after a repaint.
* The timer only invalidates the window when this flag is set, so there are no unnecessary repaints.

### Keyboard mapping

CHIP-8 keypad:

```text
1  2  3  C
4  5  6  D
7  8  9  E
A  0  B  F
```

Mapped to PC keyboard:

```text
1  2  3  4
Q  W  E  R
A  S  D  F
Z  X  C  V
```

Details:

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

* **ESC** – triggers `WM_DESTROY`/`WM_QUIT` to close the emulator.

---

## Timing & main loop

The emulator uses a **Win32 timer**:

```c
SetTimer(hWndMain, TIMER_ID_STEP, TIMER_INTERVAL_MS, NULL);
```

* `TIMER_INTERVAL_MS = 16` (approx. 60 Hz).

On each `WM_TIMER` (`WndProc_do_timer`):

1. Run `chip8_step` multiple times (currently **8** steps per tick).
2. Call `chip8_tick_timers` to decrement delay/sound timers (if non-zero).
3. Check the **DIRTY** flag in `chip8_state`:

   * If `DIRTY == 1` → `InvalidateRect(hWndMain, NULL, TRUE)` to trigger a repaint.
   * If `DIRTY == 0` → no redraw (saves GDI work and CPU).

So the default CPU rate is roughly:

* ~**500 instructions per second** (8 steps × ~62.5 ticks).

If games feel too slow/fast, you can tune:

* `TIMER_INTERVAL_MS` (timer frequency), and/or
* the “steps per tick” constant inside `WndProc_do_timer`:

```asm
WndProc_do_timer:
    movl  $8, %ecx          # steps per tick (increase for faster CPU)
WndProc_timer_loop:
    call  chip8_step
    decl  %ecx
    jnz   WndProc_timer_loop
    ...
```

The main thread uses a **classic `GetMessage` loop**, so the process stays responsive even while the VM is running.

---

## Memory layout

All CHIP-8 state is stored in a single `.bss` block (`chip8_state`) with fixed offsets:

```text
OFF_MEMORY    = 0           ; 4 KiB main memory (0x000–0xFFF)
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

* `chip8_init`:

  * Zeroes the entire state (`CHIP8_SIZE` bytes).
  * Sets `PC = 0x200`.
  * Copies built-in font sprites into `memory[0x50..]`.
  * Seeds RNG (`chip8_rng_state = 1`).

* ROM loading (`load_rom`):

  * Uses `CreateFileA` / `ReadFile` into `memory[0x200..(4096-1)]`.
  * Dumps the first 4 bytes of `memory[0x200..0x203]` for debugging.

---

## Instruction set & quirks

The interpreter implements the core CHIP-8 opcodes, including:

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
* Arithmetic/logic:

  * `6xkk` — LD Vx, kk
  * `7xkk` — ADD Vx, kk
  * `8xy0`..`8xy7`, `8xyE`
* Random:

  * `Cxkk` — RND Vx, kk using a simple LCG (`rng_next_byte`).
* Drawing:

  * `Dxyn` — sprite draw, XOR, VF set on collision.
* Timers & memory:

  * `Fx07`, `Fx0A`
  * `Fx15`, `Fx18`
  * `Fx1E`, `Fx29`, `Fx33`
  * `Fx55`, `Fx65`

### Implemented “classic” quirks

This core is biased towards **classic CHIP-8 behavior**:

* **Shift ops (`8xy6`, `8xyE`)**:

  * Use **VY** as the source.
  * `VF` = LSB/MSB of **VY** before shift.
  * `VX` receives the shifted result.

* **`Bnnn`**:

  * Jump target is `V0 + nnn`.

* **`Fx1E`**:

  * `I = (I + Vx) & 0x0FFF`.
  * `VF` is **not** modified.

* **`Fx55` / `Fx65`**:

  * After store/load, `I` becomes `I + X + 1` (wrapped to 0x0FFF),
    matching older interpreters that rely on this quirk.

### `Fx0A` (LD Vx, K) – non-blocking wait

`Fx0A` is implemented as a **true “wait for key”** but without freezing the Win32 GUI:

* On `Fx0A`:

  1. It scans the key table:

     * If **any key is currently pressed**, the key index is stored into `Vx` immediately and execution continues.
  2. If **no key is pressed**:

     * `OFF_WAITFLAG` is set to `1`.
     * `OFF_WAITREG` is set to `x` (the index of `Vx`).
     * The interpreter “blocks” **logically**, but only inside the VM:

       * The next `chip8_step` entry checks `WAITFLAG` and **returns immediately** without fetching or executing any opcode.
       * Timers and the Windows message loop keep running, so the window stays responsive.

* On key events (`WM_KEYDOWN`):

  * `map_key` converts the virtual-key code to a CHIP-8 index (0..15).
  * `chip8_set_key(key, 1)`:

    * Updates the `OFF_KEYS` table.
    * If `OFF_WAITFLAG != 0` and this is a **press** event:

      * Writes the key index into `V[OFF_WAITREG]`.
      * Clears `OFF_WAITFLAG`.
      * On the next timer tick, `chip8_step` resumes normal execution from the instruction after `Fx0A`.

This keeps the behavior close to the original “press a key to continue” semantics while staying fully event-driven and non-blocking on Windows.

---

## Error handling & debugging

### ROM loading

If the ROM cannot be opened:

```text
Failed to open ROM file
```

Then the program returns after initialization. Verify:

* Path / filename.
* Permissions.
* Working directory.

### Debug prints

On successful load, you’ll see something like:

```text
Loaded ROM: ROMS/test0.ch8
ROM[0x200..0x203] = 00 E0 60 04
After init+load
RegisterClassExA = 49967
hWndMain = 00000000007D09E4
```

These are useful to confirm:

* The ROM is loaded at the correct offset (`0x200`).
* Early opcodes look sane.
* Win32 class registration succeeded.
* The main window handle is valid.

If the window opens but remains black:

* Make sure your ROM actually draws to the screen (uses `Dxyn`).
* Check that `PC` starts at `0x200` and that the first opcodes make sense.
* Verify that the timer is firing (the process should consume a small but non-zero amount of CPU).
* Confirm that `OFF_DIRTY` is being set (e.g. by executing `00E0` or a drawing opcode).

---

## Implementation notes (dev-oriented)

* Language: **x86-64 assembly, GAS (AT&T syntax)**.

* Toolchain: **MinGW-w64**, linked directly to Win32 API:

  * `user32.dll`, `gdi32.dll`, `kernel32.dll`.

* No C sources are required at runtime; `printf` is used purely for console debugging.

* Core routines:

  * `chip8_init` – state zero/init, font load, RNG seed.
  * `chip8_step` – fetch/decode/execute one opcode (honors `WAITFLAG`).
  * `chip8_tick_timers` – decreases delay/sound at ~60 Hz.
  * `chip8_set_key` – updates key state table and wakes `Fx0A` waits.
  * `chip8_render_window` – paints current framebuffer to the window and clears `DIRTY`.
  * `WndProc` – full Win32 window procedure (paint/timer/keyboard/quit).
  * `load_rom` – WinAPI-based ROM loading and debug dump.

* Addressing conventions:

  * `%rbx` usually holds the base pointer to `chip8_state`.
  * Fixed offsets (`OFF_*`) are used with indexed addressing to access fields.
  * Opcodes are fetched from `memory[PC]` / `memory[PC+1]` with `PC` normalized to 12 bits (`0x000–0xFFF`).

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

A window appears showing the 64×32 display scaled up.

Use the mapped keys (`1 2 3 4 / Q W E R / A S D F / Z X C V`) to interact with the ROM; press **ESC** to exit.

---

## License

[MIT License](./LICENSE)

