    .att_syntax prefix

    # =========================================================================
    # CHIP-8 VM – Windows x64, AT&T syntax (GAS)
    #
    # Calling convention: Microsoft x64
    #   - Integer/pointer arguments: RCX, RDX, R8, R9
    #   - Caller allocates 32-byte shadow space on the stack for calls
    #   - RAX, RCX, RDX, R8–R11 are volatile
    #   - RBX, RBP, RSI, RDI, R12–R15 are non-volatile and must be preserved
    #
    # This file implements:
    #   - Core CHIP-8 state and interpreter (classic quirks)
    #   - 64x32 monochrome framebuffer
    #   - Win32 window + paint loop
    #   - Timer-based CPU stepping at ~60 Hz
    #   - Dirty-flag based rendering (only repaint when display changes)
    #   - Fx0A "wait for key" semantics using a non-blocking, event-driven scheme
    #   - Sound: OFF_SOUND > 0 → CDP1802-based beep (pre-rendered 1s WAV)
    # =========================================================================

    .section .bss
    .align 16

    # -------------------------------------------------------------------------
    # CHIP-8 state layout (single struct: chip8_state)
    # -------------------------------------------------------------------------
    .equ OFF_MEMORY,    0                    # 4 KB memory (0x000–0xFFF)
    .equ OFF_V,         OFF_MEMORY + 4096    # 16 general registers V0..VF (1B)
    .equ OFF_I,         OFF_V + 16           # Index register I (16-bit)
    .equ OFF_PC,        OFF_I + 2            # Program counter PC (16-bit)
    .equ OFF_SP,        OFF_PC + 2           # Stack pointer SP (8-bit, 0..15)
    .equ OFF_STACK,     OFF_SP + 1           # Call stack (16 entries, 16-bit)
    .equ OFF_GFX,       OFF_STACK + 16*2     # 64x32 display buffer (2048 B)
    .equ OFF_DELAY,     OFF_GFX + 64*32      # Delay timer (8-bit)
    .equ OFF_SOUND,     OFF_DELAY + 1        # Sound timer (8-bit)
    .equ OFF_KEYS,      OFF_SOUND + 1        # Key state array (16 bytes, 0/1)
    .equ OFF_DIRTY,     OFF_KEYS + 16        # 1 if framebuffer changed

    # Fx0A waiting state:
    #   - WAITFLAG = 0 -> not waiting
    #   - WAITFLAG = 1 -> Fx0A is currently blocking for a key
    #   - WAITREG = index of Vx where the key value should be stored
    .equ OFF_WAITFLAG,  OFF_DIRTY + 1        # 1 = waiting for key (Fx0A)
    .equ OFF_WAITREG,   OFF_WAITFLAG + 1     # target V register index (0..15)

    .equ CHIP8_SIZE,    OFF_WAITREG + 1      # Total size of chip8_state

    .globl chip8_state
chip8_state:
    .space CHIP8_SIZE                       # Single instance of CHIP-8 VM state

    .globl chip8_rng_state
chip8_rng_state:
    .long 0                                 # Simple LCG RNG state (zero init)

    # Whether sound(PlaySound) is currently playing on the Windows side.
    # 0 = Not playing.
    # 1 = Playing.
    .globl chip8_sound_on_flag
chip8_sound_on_flag:
    .byte 0

    # -------------------------------------------------------------------------
    # Win32 globals
    # -------------------------------------------------------------------------
    .globl hInstance
hInstance:
    .quad 0                                 # Process HINSTANCE

    .globl hWndMain
hWndMain:
    .quad 0                                 # Main application window handle

    .globl hBrushOn
hBrushOn:
    .quad 0                                 # GDI brush for "pixel on" (white)

    .globl hBrushOff
hBrushOff:
    .quad 0                                 # GDI brush for "pixel off" (black)

    .globl rom_filename
rom_filename:
    .quad 0                                 # Pointer to ROM filename (argv[1])

    # -------------------------------------------------------------------------
    # Fixed-size Win32 helper buffers
    # -------------------------------------------------------------------------
msg_buf:
    .space 56                               # MSG structure
wcex_buf:
    .space 80                               # WNDCLASSEX structure
ps_buf:
    .space 72                               # PAINTSTRUCT structure
rect_buf:
    .space 16                               # RECT structure
read_bytes:
    .long 0                                 # Number of bytes read by ReadFile

    .section .rodata
    # -------------------------------------------------------------------------
    # Built-in CHIP-8 font (classic 0x0–0xF, 4x5 pixels, 5 bytes per glyph)
    # Stored at memory address 0x050 at init time.
    # -------------------------------------------------------------------------
chip8_font:
    .byte 0xF0,0x90,0x90,0x90,0xF0   # 0
    .byte 0x20,0x60,0x20,0x20,0x70   # 1
    .byte 0xF0,0x10,0xF0,0x80,0xF0   # 2
    .byte 0xF0,0x10,0xF0,0x10,0xF0   # 3
    .byte 0x90,0x90,0xF0,0x10,0x10   # 4
    .byte 0xF0,0x80,0xF0,0x10,0xF0   # 5
    .byte 0xF0,0x80,0xF0,0x90,0xF0   # 6
    .byte 0xF0,0x10,0x20,0x40,0x40   # 7
    .byte 0xF0,0x90,0xF0,0x90,0xF0   # 8
    .byte 0xF0,0x90,0xF0,0x10,0xF0   # 9
    .byte 0xF0,0x90,0xF0,0x90,0x90   # A
    .byte 0xE0,0x90,0xE0,0x90,0xE0   # B
    .byte 0xF0,0x80,0x80,0x80,0xF0   # C
    .byte 0xE0,0x90,0x90,0x90,0xE0   # D
    .byte 0xF0,0x80,0xF0,0x80,0xF0   # E
    .byte 0xF0,0x80,0xF0,0x80,0x80   # F
    .equ CHIP8_FONT_SIZE, . - chip8_font

    # -------------------------------------------------------------------------
    # Debug / UI format strings
    # -------------------------------------------------------------------------
fmt_usage:
    .string "Usage: chip8 <romfile>\n"
fmt_loaded:
    .string "Loaded ROM: %s\n"

fmt_openfail:
    .string "Failed to open ROM file\n"

fmt_romdump:
    .string "ROM[0x200..0x203] = %02X %02X %02X %02X\n"

fmt_after_init:
    .string "After init+load\n"
fmt_hwnd:
    .string "hWndMain = %p\n"
fmt_regcls:
    .string "RegisterClassExA = %u\n"

className:
    .string "Chip8WinClass"
windowTitle:
    .string "CHIP-8 VM"

    # ---------------------------------------------------------------------
    # WAV header for 1-second, 8 kHz, 8-bit mono PCM.
    # PCM data (8000 bytes) is generated at runtime using CDP1802 audio core
    # and stored immediately after this header.
    # ---------------------------------------------------------------------

    .section .data
    .align 4
chip8_beep_wav:
    .ascii "RIFF"
    .long 8036                # ChunkSize = 36 + Subchunk2Size (8000)
    .ascii "WAVE"
    .ascii "fmt "
    .long 16                  # Subchunk1Size (PCM)
    .word 1                   # AudioFormat = 1 (PCM)
    .word 1                   # NumChannels = 1
    .long 8000                # SampleRate = 8000 Hz
    .long 8000                # ByteRate = SampleRate * Channels * Bits/8
    .word 1                   # BlockAlign = Channels * Bits/8
    .word 8                   # BitsPerSample = 8
    .ascii "data"
    .long 8000                # Subchunk2Size = 8000 bytes (1 second)

# 8000 bytes of PCM data will be filled at runtime from cdp1802_audio_sample
chip8_beep_pcm:
    .space 8000

    .section .text
    .globl chip8_init
    .globl chip8_tick_timers
    .globl chip8_set_key
    .globl chip8_step
    .globl chip8_render_window
    .globl WndProc
    .globl load_rom
    .globl main
    .globl chip8_build_beep_pcm
    .globl chip8_start_beep
    .globl chip8_stop_beep

    # -------------------------------------------------------------------------
    # External C / Win32 APIs
    # -------------------------------------------------------------------------
    .extern printf

    .extern GetModuleHandleA
    .extern RegisterClassExA
    .extern CreateWindowExA
    .extern ShowWindow
    .extern UpdateWindow
    .extern PeekMessageA
    .extern TranslateMessage
    .extern DispatchMessageA
    .extern DefWindowProcA
    .extern BeginPaint
    .extern EndPaint
    .extern FillRect
    .extern CreateSolidBrush
    .extern DeleteObject
    .extern InvalidateRect
    .extern PostQuitMessage
    .extern CreateFileA
    .extern ReadFile
    .extern CloseHandle

    .extern GetMessageA
    .extern SetTimer
    .extern KillTimer

    .extern PlaySoundA

    # -------------------------------------------------------------------------
    # External CDP1802 core / audio (from cdp1802.asm)
    # -------------------------------------------------------------------------
    .extern cdp1802_init
    .extern cdp1802_load
    .extern cdp1802_audio_sample
    .extern cdp1802_beep_rom

    # size of the beep ROM in bytes (REQ / LBR / SEQ / LBR)
    .equ CDP1802_BEEP_ROM_SIZE, 8

    # -------------------------------------------------------------------------
    # Win32 constants
    # -------------------------------------------------------------------------
    .equ WM_DESTROY,   0x0002
    .equ WM_PAINT,     0x000F
    .equ WM_KEYDOWN,   0x0100
    .equ WM_KEYUP,     0x0101
    .equ WM_TIMER,     0x0113
    .equ WM_QUIT,      0x0012

    .equ CS_VREDRAW,   0x0001
    .equ CS_HREDRAW,   0x0002

    .equ SW_SHOWDEFAULT, 10
    .equ CW_USEDEFAULT,  0x80000000

    .equ WS_OVERLAPPEDWINDOW, 0x00CF0000

    .equ VK_ESCAPE, 0x1B

    .equ BLACK_RGB, 0x00000000
    .equ WHITE_RGB, 0x00FFFFFF

    .equ SCALE, 10               # Size multiplier for each CHIP-8 pixel

    # MSG offsets (unused here, but defined for completeness)
    .equ MSG_HWND,    0
    .equ MSG_MESSAGE, 8
    .equ MSG_WPARAM,  16
    .equ MSG_LPARAM,  24

    # File I/O constants
    .equ GENERIC_READ,        0x80000000
    .equ FILE_SHARE_READ,     0x00000001
    .equ OPEN_EXISTING,       3
    .equ FILE_ATTRIBUTE_NORMAL, 0x00000080
    .equ INVALID_HANDLE_VALUE, -1

    # Timer constants
    .equ TIMER_ID_STEP,      1      # Timer ID used for CPU stepping
    .equ TIMER_INTERVAL_MS, 16      # ~60 Hz (1000 / 16 ≈ 62.5)

    # PlaySound Flags
    .equ SND_SYNC,          0x0000
    .equ SND_ASYNC,         0x0001
    .equ SND_NODEFAULT,     0x0002
    .equ SND_MEMORY,        0x0004
    .equ SND_LOOP,          0x0008
    .equ SND_NOSTOP,        0x0010
    .equ SND_ALIAS,         0x00010000

# ============================================================================  
# CHIP-8 CORE
# ============================================================================

# ----------------------------------------------------------------------------
# void chip8_init(void)
#
# Initializes the entire CHIP-8 state:
#   - Clears chip8_state (including DIRTY and wait flags)
#   - Sets PC to 0x200
#   - Copies built-in font into memory at 0x050
#   - Seeds the pseudo-RNG
#   - Builds 1-second CDP1802-based beep PCM into chip8_beep_pcm
# ----------------------------------------------------------------------------
chip8_init:
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx
    pushq %rsi
    pushq %rdi

    leaq  chip8_state(%rip), %rbx

    movl  $CHIP8_SIZE, %ecx
    xorl  %eax, %eax
    movq  %rbx, %rdi
.Lci_zero_loop:
    movb  %al, (%rdi)
    incq  %rdi
    decl  %ecx
    jnz   .Lci_zero_loop

    movw  $0x0200, OFF_PC(%rbx)           # PC starts at 0x200 (ROM entry)

    leaq  chip8_font(%rip), %rsi
    leaq  OFF_MEMORY+0x50(%rbx), %rdi     # Copy font to memory[0x050]
    movl  $CHIP8_FONT_SIZE, %ecx
.Lci_copy_font:
    movb  (%rsi), %al
    movb  %al, (%rdi)
    incq  %rsi
    incq  %rdi
    decl  %ecx
    jnz   .Lci_copy_font

    # Initialize RNG seed to 1
    movl  $1, chip8_rng_state(%rip)

    # Build beep PCM (1s @ 8kHz) via CDP1802 audio core
    call  chip8_build_beep_pcm

    popq  %rdi
    popq  %rsi
    popq  %rbx
    popq  %rbp
    ret


# ----------------------------------------------------------------------------
# chip8_build_beep_pcm
#
# Uses the CDP1802 core to generate 8000 samples (1 second at 8 kHz) into
# chip8_beep_pcm. The resulting memory block [chip8_beep_wav .. ] is a valid
# in-memory WAV image for PlaySoundA with SND_MEMORY | SND_LOOP.
#
# Steps:
#   - cdp1802_init()
#   - cdp1802_load(cdp1802_beep_rom, 0x0000, CDP1802_BEEP_ROM_SIZE)
#   - For i in 0..7999:
#       sample = cdp1802_audio_sample(1);  // 1 step per sample (≈2kHz beep)
#       chip8_beep_pcm[i] = sample;
# ----------------------------------------------------------------------------
chip8_build_beep_pcm:
    pushq %rbp
    movq  %rsp, %rbp

    # Initialize 1802 core
    call  cdp1802_init

    # Load beep ROM at address 0x0000
    leaq  cdp1802_beep_rom(%rip), %rcx   # src
    xorl  %edx, %edx                     # addr = 0
    movl  $CDP1802_BEEP_ROM_SIZE, %r8d   # len
    call  cdp1802_load

    # Generate 8000 samples into chip8_beep_pcm
    leaq  chip8_beep_pcm(%rip), %r10
    movl  $8000, %r11d

.Lbb_loop:
    movl  $1, %ecx                       # steps_per_sample = 1
    call  cdp1802_audio_sample           # AL = sample 0..255
    movb  %al, (%r10)
    incq  %r10
    decl  %r11d
    jnz   .Lbb_loop

    popq  %rbp
    ret


# ----------------------------------------------------------------------------
# void chip8_tick_timers(void)
#
# 60Hz Timer:
# - If delay > 0, decrement by 1
# - If sound > 0, decrement by 1
# - If sound > 0, call chip8_start_beep()
# - If sound == 0, call chip8_stop_beep()
# ----------------------------------------------------------------------------
chip8_tick_timers:
    pushq %rbp
    movq  %rsp, %rbp

    # RBX is non-volatile, so it is safest to push/pop it directly.
    pushq %rbx

    # Win64: Ensure at least 32 bytes of shadow space
    subq  $32, %rsp

    leaq  chip8_state(%rip), %rbx

    # -------------------------
    # Reduce Delay Timer
    # -------------------------
    movzbl OFF_DELAY(%rbx), %eax
    testb %al, %al
    jz    .Lct_no_delay
    decb  %al
    movb  %al, OFF_DELAY(%rbx)
.Lct_no_delay:

    # -------------------------
    # Reduce Sound Timer
    # -------------------------
    movzbl OFF_SOUND(%rbx), %eax
    testb %al, %al
    jz    .Lct_after_sound_dec
    decb  %al
    movb  %al, OFF_SOUND(%rbx)
.Lct_after_sound_dec:

    # -------------------------
    # Sound on/off toggle
    # -------------------------
    movzbl OFF_SOUND(%rbx), %eax
    testb %al, %al
    jz    .Lct_sound_off

    # ST > 0 -> Always on
    call  chip8_start_beep
    jmp   .Lct_done

.Lct_sound_off:
    # ST == 0 -> should be off
    call  chip8_stop_beep

.Lct_done:
    addq  $32, %rsp
    popq  %rbx
    popq  %rbp
    ret


# ----------------------------------------------------------------------------
# void chip8_set_key(unsigned key, unsigned pressed)
#
# Windows x64:
#   RCX = key (0..15)
#   EDX = pressed (0 = released, non-zero = pressed)
#
# Writes the key state into OFF_KEYS[key].
# Also, if Fx0A is waiting for a key (WAITFLAG != 0) and this is a press,
# it stores the key index into V[WAITREG] and clears WAITFLAG.
# ----------------------------------------------------------------------------
chip8_set_key:
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx

    leaq  chip8_state(%rip), %rbx
    andl  $0x0F, %ecx              # clamp key index 0..15

    testl %edx, %edx
    setne %al                      # AL = 1 if pressed != 0
    movb  %al, OFF_KEYS(%rbx,%rcx,1)

    # --------------------------------------------------------
    # Fx0A completion logic:
    # If this is a KEY DOWN event and Fx0A is waiting,
    #   V[WAITREG] = key index
    #   WAITFLAG   = 0 (resume execution)
    # --------------------------------------------------------
    testl %edx, %edx               # pressed? (non-zero)
    jz    .Lck_done                # key up -> do nothing for Fx0A

    movzbl OFF_WAITFLAG(%rbx), %eax
    testl  %eax, %eax
    jz     .Lck_done               # not in Fx0A wait

    # We are in Fx0A "waiting for next press".
    movzbl OFF_WAITREG(%rbx), %eax # EAX = target V-register index
    andl   $0x0F, %eax

    movb   %cl, OFF_V(%rbx,%rax,1) # V[target] = key index (ECX = key)

    movb   $0, OFF_WAITFLAG(%rbx)  # clear wait state

.Lck_done:
    popq  %rbx
    popq  %rbp
    ret

# ----------------------------------------------------------------------------
# rng_next_byte
#
# Returns:
#   AL = pseudo-random byte
#
# Simple linear congruential generator; state stored in chip8_rng_state.
# ----------------------------------------------------------------------------
rng_next_byte:
    pushq %rbp
    movq  %rsp, %rbp

    movl  chip8_rng_state(%rip), %eax
    movl  $1103515245, %ecx
    imull %ecx, %eax
    addl  $12345, %eax
    movl  %eax, chip8_rng_state(%rip)

    shrl  $16, %eax
    andl  $0xFF, %eax          # Keep low 8 bits

    popq  %rbp
    ret


# ============================================================================  
# chip8_step
#
# void chip8_step(void)
#
# Executes exactly one CHIP-8 instruction at the current PC.
# Implements classic CHIP-8 quirks (8xy6, 8xyE, Bnnn, Fx55, Fx65).
# Fx0A semantics:
#   - If a key is already pressed, Vx = key index, then continue.
#   - If no key is pressed, interpreter enters a "waiting" state:
#       WAITFLAG = 1, WAITREG = x, and subsequent chip8_step calls do nothing
#       until a key press event arrives via chip8_set_key.
# ============================================================================  
chip8_step:
    pushq %rbp
    movq  %rsp, %rbp

    # Save non-volatile registers
    pushq %rbx
    pushq %rsi
    pushq %rdi
    pushq %r12
    pushq %r13
    pushq %r14

    # Reserve shadow space (for any calls inside this function)
    subq  $32, %rsp

    # RBX = base pointer to chip8_state
    leaq  chip8_state(%rip), %rbx

    # If Fx0A is currently waiting for a key, do not execute anything.
    # Timers and window messages continue to run outside this function.
    movzbl OFF_WAITFLAG(%rbx), %eax
    testl %eax, %eax
    jnz   .STEP_WAITING

    # ------------------------------------------------------
    # Fetch PC, normalize to 12 bits (0..0xFFF), and write back
    # ------------------------------------------------------
    movw  OFF_PC(%rbx), %ax        # 16-bit PC
    andl  $0x0FFF, %eax            # 12-bit address space
    movw  %ax, OFF_PC(%rbx)

    movl  %eax, %ecx               # ECX = PC
    movslq %ecx, %rcx              # RCX = PC (for addressing)

    # RSI = pointer to memory[0]
    leaq  OFF_MEMORY(%rbx), %rsi

    # ------------------------------------------------------
    # Fetch 16-bit opcode: memory[PC] << 8 | memory[PC + 1]
    # ------------------------------------------------------
    movzbl (%rsi,%rcx,1), %edx
    shll   $8, %edx
    movzbl 1(%rsi,%rcx,1), %edi
    orl    %edi, %edx
    movl   %edx, %r13d             # R13D = opcode

    # ------------------------------------------------------
    # Advance PC by 2 (wrap to 12 bits). Individual opcodes
    # may override PC again for jumps/calls/skips.
    # ------------------------------------------------------
    movw  OFF_PC(%rbx), %ax
    addw  $2, %ax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)

    # Top-level decode by high nibble (opcode >> 12)
    movl   %r13d, %eax
    shrl   $12, %eax
    andl   $0x0F, %eax
    movl   %eax, %ecx

    cmpl   $0x0, %ecx
    je     .OP_0xxx
    cmpl   $0x1, %ecx
    je     .OP_1nnn
    cmpl   $0x2, %ecx
    je     .OP_2nnn
    cmpl   $0x3, %ecx
    je     .OP_3xkk
    cmpl   $0x4, %ecx
    je     .OP_4xkk
    cmpl   $0x5, %ecx
    je     .OP_5xy0
    cmpl   $0x6, %ecx
    je     .OP_6xkk
    cmpl   $0x7, %ecx
    je     .OP_7xkk
    cmpl   $0x8, %ecx
    je     .OP_8xy_
    cmpl   $0x9, %ecx
    je     .OP_9xy0
    cmpl   $0xA, %ecx
    je     .OP_Annn
    cmpl   $0xB, %ecx
    je     .OP_Bnnn
    cmpl   $0xC, %ecx
    je     .OP_Cxkk
    cmpl   $0xD, %ecx
    je     .OP_Dxyn
    cmpl   $0xE, %ecx
    je     .OP_Ex__
    cmpl   $0xF, %ecx
    je     .OP_Fx__
    jmp    .STEP_END

# ----------------------------------------------------------------------------
# 0x0??? group
#   00E0: CLS
#   00EE: RET
# ----------------------------------------------------------------------------
.OP_0xxx:
    movl  %r13d, %eax
    andl  $0x00FF, %eax
    cmpl  $0xE0, %eax
    je    .OP_00E0
    cmpl  $0xEE, %eax
    je    .OP_00EE
    jmp   .STEP_END

.OP_00E0:                  # CLS: clear the 64x32 display buffer
    movb  $1, OFF_DIRTY(%rbx)       # Mark framebuffer dirty

    leaq  OFF_GFX(%rbx), %rdi
    movl  $64*32, %ecx
    xorl  %eax, %eax
.Lcls_loop:
    movb  %al, (%rdi)
    incq  %rdi
    decl  %ecx
    jnz   .Lcls_loop
    jmp   .STEP_END

.OP_00EE:                  # RET: PC = pop() from call stack
    movzbl OFF_SP(%rbx), %eax
    andl  $0x0F, %eax
    decl  %eax
    andl  $0x0F, %eax
    movb  %al, OFF_SP(%rbx)

    movzbl %al, %ecx
    imull $2, %ecx, %ecx               # index = SP * 2
    movslq %ecx, %rcx
    movw  OFF_STACK(%rbx,%rcx,1), %dx
    andl  $0x0FFF, %edx
    movw  %dx, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 1nnn: JP nnn
#   PC = nnn
# ----------------------------------------------------------------------------
.OP_1nnn:
    movl  %r13d, %eax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 2nnn: CALL nnn
#   stack[SP] = PC; SP++; PC = nnn
# ----------------------------------------------------------------------------
.OP_2nnn:
    movzbl OFF_SP(%rbx), %eax
    andl  $0x0F, %eax
    movl  %eax, %ecx
    imull $2, %ecx, %ecx               # index = SP * 2
    movslq %ecx, %rcx

    movw  OFF_PC(%rbx), %si            # current PC (already advanced)
    movw  %si, OFF_STACK(%rbx,%rcx,1)

    incl  %eax
    andl  $0x0F, %eax
    movb  %al, OFF_SP(%rbx)

    movl  %r13d, %eax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 3xkk: SE Vx, kk
#   if (Vx == kk) PC += 2
# ----------------------------------------------------------------------------
.OP_3xkk:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    andl  $0x00FF, %eax                # EAX = kk
    movzbl OFF_V(%rbx,%rcx,1), %edi    # EDI = Vx
    cmpl  %eax, %edi
    jne   .STEP_END
    movw  OFF_PC(%rbx), %ax
    addw  $2, %ax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 4xkk: SNE Vx, kk
#   if (Vx != kk) PC += 2
# ----------------------------------------------------------------------------
.OP_4xkk:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    andl  $0x00FF, %eax                # EAX = kk
    movzbl OFF_V(%rbx,%rcx,1), %edi
    cmpl  %eax, %edi
    je    .STEP_END
    movw  OFF_PC(%rbx), %ax
    addw  $2, %ax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 5xy0: SE Vx, Vy
#   if (Vx == Vy) PC += 2
# ----------------------------------------------------------------------------
.OP_5xy0:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    movl  %eax, %edi
    shrl  $4, %edi
    andl  $0x0F, %edi                  # EDI = y
    andl  $0x000F, %eax                # low nibble must be 0
    cmpl  $0, %eax
    jne   .STEP_END
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movzbl OFF_V(%rbx,%rdi,1), %esi
    cmpl  %esi, %eax
    jne   .STEP_END
    movw  OFF_PC(%rbx), %ax
    addw  $2, %ax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 6xkk: LD Vx, kk
# ----------------------------------------------------------------------------
.OP_6xkk:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    andl  $0x00FF, %eax                # EAX = kk
    movb  %al, OFF_V(%rbx,%rcx,1)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 7xkk: ADD Vx, kk
#   Vx = (Vx + kk) & 0xFF (no carry flag)
# ----------------------------------------------------------------------------
.OP_7xkk:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    andl  $0x00FF, %eax                # EAX = kk
    movzbl OFF_V(%rbx,%rcx,1), %edi    # EDI = Vx
    addl  %eax, %edi                   # Vx += kk
    movb  %dil, OFF_V(%rbx,%rcx,1)     # store low 8 bits
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 8xy? group: arithmetic and bitwise ops on Vx, Vy
# ----------------------------------------------------------------------------
.OP_8xy_:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    movl  %eax, %edi
    shrl  $4, %edi
    andl  $0x0F, %edi                  # EDI = y
    andl  $0x000F, %eax                # low nibble selects the operation

    cmpl  $0x0, %eax
    je    .OP_8xy0
    cmpl  $0x1, %eax
    je    .OP_8xy1
    cmpl  $0x2, %eax
    je    .OP_8xy2
    cmpl  $0x3, %eax
    je    .OP_8xy3
    cmpl  $0x4, %eax
    je    .OP_8xy4
    cmpl  $0x5, %eax
    je    .OP_8xy5
    cmpl  $0x6, %eax
    je    .OP_8xy6
    cmpl  $0x7, %eax
    je    .OP_8xy7
    cmpl  $0xE, %eax
    je    .OP_8xyE
    jmp   .STEP_END

.OP_8xy0:                  # LD Vx, Vy
    movzbl OFF_V(%rbx,%rdi,1), %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END

.OP_8xy1:                  # OR Vx, Vy
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movzbl OFF_V(%rbx,%rdi,1), %esi
    orl    %esi, %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END

.OP_8xy2:                  # AND Vx, Vy
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movzbl OFF_V(%rbx,%rdi,1), %esi
    andl   %esi, %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END

.OP_8xy3:                  # XOR Vx, Vy
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movzbl OFF_V(%rbx,%rdi,1), %esi
    xorl   %esi, %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END

.OP_8xy4:                  # ADD Vx, Vy (with carry -> VF)
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movzbl OFF_V(%rbx,%rdi,1), %esi
    movb   $0, OFF_V+15(%rbx)
    addl   %esi, %eax
    cmpl   $0xFF, %eax
    jbe    .Lno_carry_8xy4
    movb   $1, OFF_V+15(%rbx)
.Lno_carry_8xy4:
    andl   $0xFF, %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END

.OP_8xy5:                  # SUB Vx, Vy (VF = !borrow)
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movzbl OFF_V(%rbx,%rdi,1), %esi
    movb   $0, OFF_V+15(%rbx)
    cmpl   %esi, %eax
    jb     .Lborrow_8xy5
    movb   $1, OFF_V+15(%rbx)
    subl   %esi, %eax
    andl   $0xFF, %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END
.Lborrow_8xy5:
    subl   %esi, %eax
    andl   $0xFF, %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END

# Classic CHIP-8 quirk:
# 8xy6 and 8xyE shift Vy, write result into Vx, and set VF from Vy.
.OP_8xy6:                  # SHR Vx {, Vy}
    #   VF = LSB(Vy)
    #   Vx = Vy >> 1
    movl  %ecx, %esi                  # Save x index in ESI
    movl  %edi, %ecx                  # ECX = y index
    movzbl OFF_V(%rbx,%rcx,1), %eax   # EAX = Vy
    movb  $0, OFF_V+15(%rbx)          # VF = 0
    testb $1, %al
    jz    .Lno_lsb_8xy6
    movb  $1, OFF_V+15(%rbx)          # If LSB(Vy) == 1, VF = 1
.Lno_lsb_8xy6:
    shrb  $1, %al                     # AL = Vy >> 1
    movl  %esi, %ecx                  # Restore x index
    movb  %al, OFF_V(%rbx,%rcx,1)     # Vx = result
    jmp   .STEP_END

.OP_8xy7:                  # SUBN Vx, Vy (Vx = Vy - Vx; VF = !borrow)
    movzbl OFF_V(%rbx,%rcx,1), %eax   # EAX = Vx
    movzbl OFF_V(%rbx,%rdi,1), %esi   # ESI = Vy
    movb   $0, OFF_V+15(%rbx)
    cmpl   %eax, %esi
    jb     .Lborrow_8xy7
    movb   $1, OFF_V+15(%rbx)
    movl   %esi, %edx
    subl   %eax, %edx
    andl   $0xFF, %edx
    movb   %dl, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END
.Lborrow_8xy7:
    movl   %esi, %edx
    subl   %eax, %edx
    andl   $0xFF, %edx
    movb   %dl, OFF_V(%rbx,%rcx,1)
    jmp   .STEP_END

.OP_8xyE:                  # SHL Vx {, Vy}
    #   VF = MSB(Vy)
    #   Vx = Vy << 1
    movl  %ecx, %esi                  # Save x index
    movl  %edi, %ecx                  # ECX = y index
    movzbl OFF_V(%rbx,%rcx,1), %eax   # EAX = Vy
    movb  $0, OFF_V+15(%rbx)          # VF = 0
    testb $0x80, %al
    jz    .Lno_msb_8xye
    movb  $1, OFF_V+15(%rbx)          # If MSB(Vy) == 1, VF = 1
.Lno_msb_8xye:
    shlb  $1, %al                     # AL = Vy << 1
    movl  %esi, %ecx                  # Restore x index
    movb  %al, OFF_V(%rbx,%rcx,1)     # Vx = result
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# 9xy0: SNE Vx, Vy
#   if (Vx != Vy) PC += 2
# ----------------------------------------------------------------------------
.OP_9xy0:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    movl  %eax, %edi
    shrl  $4, %edi
    andl  $0x0F, %edi                  # EDI = y
    andl  $0x000F, %eax                # low nibble must be 0
    cmpl  $0, %eax
    jne   .STEP_END
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movzbl OFF_V(%rbx,%rdi,1), %esi
    cmpl  %esi, %eax
    je    .STEP_END
    movw  OFF_PC(%rbx), %ax
    addw  $2, %ax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# Annn: LD I, nnn
# ----------------------------------------------------------------------------
.OP_Annn:
    movl  %r13d, %eax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_I(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# Bnnn: JP V0, nnn  (classic quirk: always uses V0)
#   PC = (V0 + nnn) & 0x0FFF
# ----------------------------------------------------------------------------
.OP_Bnnn:
    movl  %r13d, %eax
    andl  $0x0FFF, %eax               # EAX = nnn
    movzbl OFF_V(%rbx), %esi          # ESI = V0
    addl  %esi, %eax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# Cxkk: RND Vx, kk
#   Vx = (random_byte() & kk)
# ----------------------------------------------------------------------------
.OP_Cxkk:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                  # ECX = x
    andl  $0x00FF, %eax                # EAX = kk
    movl  %eax, %edx
    call  rng_next_byte               # AL = random
    andb  %dl, %al
    movb  %al, OFF_V(%rbx,%rcx,1)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# Dxyn: DRW Vx, Vy, nibble
#
# Draw N-byte sprite at (Vx, Vy) using memory starting at I.
# Each byte is one horizontal row of 8 pixels (MSB is leftmost).
# Wraps around screen edges. VF is set to 1 if any pixels are unset
# (collision), otherwise 0.
# ----------------------------------------------------------------------------
.OP_Dxyn:
    movb  $1, OFF_DIRTY(%rbx)         # Mark framebuffer dirty on any draw
    movl  %r13d, %eax

    # x = (opcode >> 8) & 0x0F
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx           # ECX = x index

    # y = (opcode >> 4) & 0x0F
    movl  %eax, %edx
    shrl  $4, %edx
    andl  $0x0F, %edx           # EDX = y index

    # n = opcode & 0x000F
    andl  $0x000F, %eax
    movl  %eax, %r10d           # R10D = height (N rows)

    # Read Vx, Vy
    movzbl OFF_V(%rbx,%rcx,1), %r8d  # R8D = Vx
    movzbl OFF_V(%rbx,%rdx,1), %r9d  # R9D = Vy

    # VF = 0 (no collision yet)
    movb  $0, OFF_V+15(%rbx)

    # Base pointers
    leaq  OFF_MEMORY(%rbx), %rsi     # RSI = memory base
    leaq  OFF_GFX(%rbx),    %rdi     # RDI = gfx buffer

    # I register (sprite base address)
    movw  OFF_I(%rbx), %r11w
    andl  $0x0FFF, %r11d

    xorl  %r12d, %r12d          # row = 0
.Ldraw_row:
    cmpl  %r10d, %r12d
    jge   .Ldraw_done

    # spriteByte = memory[(I + row) & 0x0FFF]
    movl  %r11d, %eax
    addl  %r12d, %eax
    andl  $0x0FFF, %eax
    movzbl (%rsi,%rax,1), %r13d

    xorl  %r14d, %r14d          # bit = 0
.Ldraw_bit:
    cmpl  $8, %r14d
    jge   .Ldraw_next_row

    testb $0x80, %r13b          # test MSB of spriteByte
    jz    .Lskip_bit

    # x = (Vx + bit) & 63
    movl  %r8d, %ecx
    addl  %r14d, %ecx
    andl  $63, %ecx

    # y = (Vy + row) & 31
    movl  %r9d, %edx
    addl  %r12d, %edx
    andl  $31, %edx

    # index = y * 64 + x
    movl  %edx, %eax
    shll  $6, %eax
    addl  %ecx, %eax
    movslq %eax, %rax

    # Read current pixel
    movzbl (%rdi,%rax,1), %edx
    testl %edx, %edx
    jz    .Lno_col
    movb  $1, OFF_V+15(%rbx)     # Collision -> VF = 1
.Lno_col:
    xorl  $1, %edx               # Toggle pixel (xor 1)
    movb  %dl, (%rdi,%rax,1)

.Lskip_bit:
    shlb  $1, %r13b              # Shift spriteByte left, next bit
    incl  %r14d
    jmp   .Ldraw_bit

.Ldraw_next_row:
    incl  %r12d
    jmp   .Ldraw_row

.Ldraw_done:
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# Ex?? group: key checks
#   Ex9E: SKP Vx  -> skip if key[Vx] is pressed
#   ExA1: SKNP Vx -> skip if key[Vx] is not pressed
# ----------------------------------------------------------------------------
.OP_Ex__:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                 # ECX = x
    andl  $0x00FF, %eax               # EAX = low byte

    cmpl  $0x9E, %eax
    je    .OP_Ex9E
    cmpl  $0xA1, %eax
    je    .OP_ExA1
    jmp   .STEP_END

.OP_Ex9E:                   # SKP Vx
    movzbl OFF_V(%rbx,%rcx,1), %eax
    andl  $0x0F, %eax                # key index 0..15
    movzbl OFF_KEYS(%rbx,%rax,1), %esi
    testl %esi, %esi
    jz    .STEP_END                  # not pressed: no skip
    movw  OFF_PC(%rbx), %ax
    addw  $2, %ax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END

.OP_ExA1:                   # SKNP Vx
    movzbl OFF_V(%rbx,%rcx,1), %eax
    andl  $0x0F, %eax
    movzbl OFF_KEYS(%rbx,%rax,1), %esi
    testl %esi, %esi
    jnz   .STEP_END                  # pressed: no skip
    movw  OFF_PC(%rbx), %ax
    addw  $2, %ax
    andl  $0x0FFF, %eax
    movw  %ax, OFF_PC(%rbx)
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# Fx?? group: miscellaneous ops
#
#   Fx07: LD Vx, DT
#   Fx0A: LD Vx, K      (blocking: wait for key; implemented with wait flag)
#   Fx15: LD DT, Vx
#   Fx18: LD ST, Vx
#   Fx1E: ADD I, Vx     (classic: I = (I + Vx) & 0x0FFF, VF untouched)
#   Fx29: LD F, Vx      (I = font address for digit in Vx)
#   Fx33: LD B, Vx      (BCD)
#   Fx55: LD [I], V0..Vx  (classic: I = I + X + 1)
#   Fx65: LD V0..Vx, [I]  (classic: I = I + X + 1)
# ----------------------------------------------------------------------------
.OP_Fx__:
    movl  %r13d, %eax
    movl  %eax, %ecx
    shrl  $8, %ecx
    andl  $0x0F, %ecx                 # ECX = x
    andl  $0x00FF, %eax               # EAX = low byte

    cmpl  $0x07, %eax
    je    .OP_Fx07
    cmpl  $0x0A, %eax
    je    .OP_Fx0A
    cmpl  $0x15, %eax
    je    .OP_Fx15
    cmpl  $0x18, %eax
    je    .OP_Fx18
    cmpl  $0x1E, %eax
    je    .OP_Fx1E
    cmpl  $0x29, %eax
    je    .OP_Fx29
    cmpl  $0x33, %eax
    je    .OP_Fx33
    cmpl  $0x55, %eax
    je    .OP_Fx55
    cmpl  $0x65, %eax
    je    .OP_Fx65
    jmp   .STEP_END

.OP_Fx07:                   # LD Vx, DT
    movzbl OFF_DELAY(%rbx), %eax
    movb   %al, OFF_V(%rbx,%rcx,1)
    jmp    .STEP_END

# ----------------------------------------------------------------------------
# Fx0A: LD Vx, K  (wait for a key, event-driven, non-blocking)
#
# Semantics:
#   - If ANY key is currently pressed: Vx = that key index, continue.
#   - If no key is pressed:
#       WAITFLAG = 1, WAITREG = x
#       PC is already advanced to the next instruction and is NOT modified.
#       Subsequent chip8_step() calls do nothing while WAITFLAG != 0.
#       When chip8_set_key() sees a key press, it writes V[WAITREG] and
#       clears WAITFLAG, then execution resumes from the next opcode.
# ----------------------------------------------------------------------------
.OP_Fx0A:
    # At this point WAITFLAG must be 0, because chip8_step() bails out
    # early when WAITFLAG != 0.

    # Phase 0: check if there is already a key held down.
    movl   $0, %edi                    # EDI = key index (0..15)

.Lfx0a_scan_pressed:
    cmpl   $16, %edi
    jge    .Lfx0a_no_key               # no key is pressed

    movzbl OFF_KEYS(%rbx,%rdi,1), %eax
    testl  %eax, %eax
    jz     .Lfx0a_next_key             # this key not pressed -> next

    # Found a pressed key -> Vx = key index, done.
    movb   %dil, OFF_V(%rbx,%rcx,1)    # Vx = EDI (key index)
    jmp    .STEP_END

.Lfx0a_next_key:
    incl   %edi
    jmp    .Lfx0a_scan_pressed

.Lfx0a_no_key:
    # No key is currently pressed:
    # enter "wait for key" state, without touching PC.
    movb   $1,  OFF_WAITFLAG(%rbx)     # Fx0A is now blocking on a key
    movb   %cl, OFF_WAITREG(%rbx)      # remember x (Vx index)
    jmp    .STEP_END



.OP_Fx15:                   # LD DT, Vx
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movb   %al, OFF_DELAY(%rbx)
    jmp    .STEP_END

.OP_Fx18:                   # LD ST, Vx
    movzbl OFF_V(%rbx,%rcx,1), %eax
    movb   %al, OFF_SOUND(%rbx)
    jmp    .STEP_END

.OP_Fx1E:                   # ADD I, Vx (classic: VF unchanged)
    movw  OFF_I(%rbx), %ax            # AX = I
    movzbl OFF_V(%rbx,%rcx,1), %esi   # ESI = Vx
    addl  %esi, %eax                  # I += Vx
    andl  $0x0FFF, %eax               # Wrap to 4K address space
    movw  %ax, OFF_I(%rbx)
    jmp    .STEP_END

.OP_Fx29:                   # LD F, Vx (font address)
    movzbl OFF_V(%rbx,%rcx,1), %eax
    andl  $0x0F, %eax                 # digit 0..F
    imull $5, %eax, %eax              # 5 bytes per glyph
    addl  $0x50, %eax                 # font base at 0x050
    movw  %ax, OFF_I(%rbx)
    jmp   .STEP_END

.OP_Fx33:                   # LD B, Vx (BCD)
    # Stores decimal representation of Vx at memory[I], memory[I+1], memory[I+2]:
    # hundreds, tens, ones.
    movzbl OFF_V(%rbx,%rcx,1), %eax  # EAX = Vx (0..255)
    movw  OFF_I(%rbx), %dx
    andl  $0x0FFF, %edx
    leaq  OFF_MEMORY(%rbx), %rsi

    movl  %eax, %edi
    movl  $0, %ecx
.Lbcd100:
    cmpl  $100, %edi
    jb    .Lbcd100_done
    subl  $100, %edi
    incl  %ecx
    jmp   .Lbcd100
.Lbcd100_done:
    movzbl %cl, %r8d                  # R8B = hundreds digit

    movl  %edi, %eax
    movl  $0, %ecx
.Lbcd10:
    cmpl  $10, %eax
    jb    .Lbcd10_done
    subl  $10, %eax
    incl  %ecx
    jmp   .Lbcd10
.Lbcd10_done:
    movzbl %cl, %r9d                  # R9B = tens digit
    movl  %eax, %r10d                 # R10B = ones digit

    movb  %r8b,  (%rsi,%rdx,1)
    movb  %r9b, 1(%rsi,%rdx,1)
    movb  %r10b,2(%rsi,%rdx,1)
    jmp   .STEP_END

.OP_Fx55:                   # LD [I], V0..Vx (classic: I = I + X + 1)
    movw  OFF_I(%rbx), %dx
    andl  $0x0FFF, %edx               # EDX = I
    leaq  OFF_MEMORY(%rbx), %rsi
    movl  $0, %eax                    # A = 0 (register index)

.Lstore:
    cmpl  %ecx, %eax                  # while A <= X
    jg    .Lstore_done

    movl  %edx, %r9d
    cmpl  $4095, %r9d
    jg    .Lstore_skip_write          # Skip if out of memory range

    movzbl OFF_V(%rbx,%rax,1), %r10d  # R10B = V[A]
    movb  %r10b, (%rsi,%r9,1)         # memory[I + A] = V[A]

.Lstore_skip_write:
    incl  %eax                        # A++
    incl  %edx                        # I++
    jmp   .Lstore

.Lstore_done:
    andl  $0x0FFF, %edx
    movw  %dx, OFF_I(%rbx)            # Classic: I = I + X + 1
    jmp   .STEP_END

.OP_Fx65:                   # LD V0..Vx, [I] (classic: I = I + X + 1)
    movw  OFF_I(%rbx), %dx
    andl  $0x0FFF, %edx               # EDX = I
    leaq  OFF_MEMORY(%rbx), %rsi
    movl  $0, %eax                    # A = 0

.Lload:
    cmpl  %ecx, %eax                  # while A <= X
    jg    .Lload_done

    movl  %edx, %r9d
    cmpl  $4095, %r9d
    jg    .Lload_skip_read            # Skip if out of memory range

    movzbl (%rsi,%r9,1), %r10d
    movb  %r10b, OFF_V(%rbx,%rax,1)   # V[A] = memory[I + A]

.Lload_skip_read:
    incl  %eax                        # A++
    incl  %edx                        # I++
    jmp   .Lload

.Lload_done:
    andl  $0x0FFF, %edx
    movw  %dx, OFF_I(%rbx)            # Classic: I = I + X + 1
    jmp   .STEP_END


# ----------------------------------------------------------------------------
# Common step epilogue and "waiting" fast-path
# ----------------------------------------------------------------------------
.STEP_WAITING:
    # Fx0A waiting state:
    #   - Do not fetch/execute any new opcode.
    #   - Timers and window messages are handled outside.
    jmp .STEP_END

.STEP_END:
    addq  $32, %rsp

    popq  %r14
    popq  %r13
    popq  %r12
    popq  %rdi
    popq  %rsi
    popq  %rbx
    popq  %rbp
    ret



# ============================================================================  
# chip8_render_window(HWND hWnd, HDC hdc)
#
# RCX = hWnd (unused here, but passed for API consistency)
# RDX = hdc  (device context to render into)
#
# Renders the 64x32 CHIP-8 framebuffer (OFF_GFX) as a scaled rectangle grid
# using FillRect and the "pixel on" brush only.
#   - Background is cleared using the window class background brush (black).
#   - Only pixels with value 1 are drawn.
#   - After drawing, the DIRTY flag is cleared to 0.
# ============================================================================  
chip8_render_window:
    pushq %rbp
    movq  %rsp, %rbp

    pushq %rbx        # Save non-volatile and working registers
    pushq %rsi
    pushq %rdi
    pushq %r12
    pushq %r13
    pushq %r14        # Padding / spare

    subq  $32, %rsp   # Shadow space for WinAPI calls

    movq  %rdx, %rbx  # RBX = HDC

    leaq  chip8_state(%rip), %rax
    leaq  OFF_GFX(%rax), %rsi        # RSI = &gfx[0]

    xorl  %r12d, %r12d               # y = 0
.Ly_loop:
    cmpl  $32, %r12d
    jge   .Lrender_done

    xorl  %r13d, %r13d               # x = 0
.Lx_loop:
    cmpl  $64, %r13d
    jge   .Lnext_row

    # index = y * 64 + x
    movl  %r12d, %eax
    shll  $6, %eax
    addl  %r13d, %eax
    movslq %eax, %rax

    movzbl (%rsi,%rax,1), %r9d       # R9D = pixel (0 or 1)
    testl %r9d, %r9d
    jz    .Lskip_pixel               # If 0, nothing is drawn

    # Fill rect for ON pixel
    movl  %r13d, %ecx
    imull $SCALE, %ecx
    movl  %ecx, rect_buf+0(%rip)     # left

    movl  %r12d, %edx
    imull $SCALE, %edx
    movl  %edx, rect_buf+4(%rip)     # top

    addl  $SCALE, %ecx
    movl  %ecx, rect_buf+8(%rip)     # right

    addl  $SCALE, %edx
    movl  %edx, rect_buf+12(%rip)    # bottom

    # FillRect(hdc, &rect, hBrushOn)
    movq  %rbx, %rcx
    leaq  rect_buf(%rip), %rdx
    movq  hBrushOn(%rip), %r8
    call  FillRect

.Lskip_pixel:
    incl  %r13d
    jmp   .Lx_loop

.Lnext_row:
    incl  %r12d
    jmp   .Ly_loop

.Lrender_done:
    addq  $32, %rsp

    # Clear DIRTY flag now that the screen has been painted
    leaq  chip8_state(%rip), %rax
    movb  $0, OFF_DIRTY(%rax)

    popq  %r14
    popq  %r13
    popq  %r12
    popq  %rdi
    popq  %rsi
    popq  %rbx
    popq  %rbp
    ret



# ============================================================================  
# load_rom(const char *filename)
#
# RCX = filename (char const *)
#
# Opens the ROM file, reads it into memory starting at 0x200, and prints a
# small debug dump of the first 4 bytes at 0x200.
# ============================================================================  
load_rom:
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx

    movq  %rcx, %rbx                 # RBX = filename pointer

    # HANDLE hFile = CreateFileA(name, GENERIC_READ, FILE_SHARE_READ,
    #                             NULL, OPEN_EXISTING,
    #                             FILE_ATTRIBUTE_NORMAL, NULL);
    movq  %rbx, %rcx                 # lpFileName
    movl  $GENERIC_READ, %edx        # dwDesiredAccess
    movl  $FILE_SHARE_READ, %r8d     # dwShareMode
    xorl  %r9d, %r9d                 # lpSecurityAttributes = NULL

    subq  $56, %rsp                  # 32 shadow + 3*8 extra args
    movl  $OPEN_EXISTING,        32(%rsp) # dwCreationDisposition
    movl  $FILE_ATTRIBUTE_NORMAL,40(%rsp) # dwFlagsAndAttributes
    movq  $0,                     48(%rsp) # hTemplateFile = NULL

    call  CreateFileA

    addq  $56, %rsp

    movq  %rax, %rbx                 # RBX = hFile
    cmpq  $INVALID_HANDLE_VALUE, %rax
    jne   .Lcf_ok

    # Open failed: print error and return
    leaq  fmt_openfail(%rip), %rcx
    subq  $40, %rsp
    xorl  %eax, %eax
    call  printf
    addq  $40, %rsp
    jmp   .Lrom_done

.Lcf_ok:
    # ReadFile(hFile, memory+0x200, 4096-0x200, &read_bytes, NULL)
    leaq  chip8_state(%rip), %rdx
    addq  $OFF_MEMORY+0x200, %rdx    # destination pointer

    movq  %rbx, %rcx                 # hFile
    movl  $(4096-0x200), %r8d        # bytes to read
    leaq  read_bytes(%rip), %r9      # number of bytes read

    subq  $40, %rsp
    movq  $0, 32(%rsp)               # lpOverlapped = NULL
    call  ReadFile
    addq  $40, %rsp

    # Close file handle
    movq  %rbx, %rcx
    subq  $40, %rsp
    call  CloseHandle
    addq  $40, %rsp

    # Debug dump of ROM[0x200..0x203]
    leaq  chip8_state(%rip), %rax
    addq  $OFF_MEMORY+0x200, %rax

    leaq  fmt_romdump(%rip), %rcx
    movzbl 0(%rax), %edx
    movzbl 1(%rax), %r8d
    movzbl 2(%rax), %r9d
    movzbl 3(%rax), %eax

    subq  $40, %rsp
    movq  %rax, 32(%rsp)
    xorl  %eax, %eax
    call  printf
    addq  $40, %rsp

.Lrom_done:
    popq  %rbx
    popq  %rbp
    ret


# ============================================================================  
# map_key
#
# Input:
#   EAX = virtual-key code (ASCII for numeric/letter keys)
#
# Output:
#   ECX = CHIP-8 key index 0..15 on success, or -1 if unmapped
#
# Keyboard layout:
#   1 2 3 4       -> 1 2 3 C
#   Q W E R       -> 4 5 6 D
#   A S D F       -> 7 8 9 E
#   Z X C V       -> A 0 B F
# ============================================================================  
map_key:
    movl  $-1, %ecx

    cmpl  $'1', %eax
    jne   1f
    movl  $0x1, %ecx
1:
    cmpl  $'2', %eax
    jne   2f
    movl  $0x2, %ecx
2:
    cmpl  $'3', %eax
    jne   3f
    movl  $0x3, %ecx
3:
    cmpl  $'4', %eax
    jne   4f
    movl  $0xC, %ecx
4:
    cmpl  $'Q', %eax
    jne   5f
    movl  $0x4, %ecx
5:
    cmpl  $'W', %eax
    jne   6f
    movl  $0x5, %ecx
6:
    cmpl  $'E', %eax
    jne   7f
    movl  $0x6, %ecx
7:
    cmpl  $'R', %eax
    jne   8f
    movl  $0xD, %ecx
8:
    cmpl  $'A', %eax
    jne   9f
    movl  $0x7, %ecx
9:
    cmpl  $'S', %eax
    jne   10f
    movl  $0x8, %ecx
10:
    cmpl  $'D', %eax
    jne   11f
    movl  $0x9, %ecx
11:
    cmpl  $'F', %eax
    jne   12f
    movl  $0xE, %ecx
12:
    cmpl  $'Z', %eax
    jne   13f
    movl  $0xA, %ecx
13:
    cmpl  $'X', %eax
    jne   14f
    movl  $0x0, %ecx
14:
    cmpl  $'C', %eax
    jne   15f
    movl  $0xB, %ecx
15:
    cmpl  $'V', %eax
    jne   16f
    movl  $0xF, %ecx
16:
    ret


# ============================================================================  
# WndProc – Window procedure
#
# LRESULT CALLBACK WndProc(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam)
#
# RCX = hWnd
# RDX = msg
# R8  = wParam
# R9  = lParam
#
# Handles:
#   - WM_PAINT   -> draws the framebuffer
#   - WM_TIMER   -> steps the CHIP-8 CPU, ticks timers, and invalidates window
#   - WM_KEYDOWN / WM_KEYUP -> updates key state (ESC quits)
#   - WM_DESTROY -> kills timer and posts WM_QUIT
# ============================================================================  
WndProc:
    pushq %rbp
    movq  %rsp, %rbp
    subq  $64, %rsp          # 32-byte home space + locals + padding

    # Save non-volatile registers above home space
    movq  %rdi, -8(%rbp)
    movq  %rsi, -16(%rbp)
    movq  %rbx, -24(%rbp)

    # Copy parameters into callee-saved registers
    movq  %rcx, %rdi         # RDI = hWnd
    movq  %rdx, %rsi         # RSI = msg
    movq  %r8,  %r10         # R10 = wParam
    movq  %r9,  %r11         # R11 = lParam

    cmpl  $WM_PAINT, %esi
    je    WndProc_do_paint
    cmpl  $WM_DESTROY, %esi
    je    WndProc_do_destroy
    cmpl  $WM_TIMER, %esi
    je    WndProc_do_timer
    cmpl  $WM_KEYDOWN, %esi
    je    WndProc_do_keydown
    cmpl  $WM_KEYUP, %esi
    je    WndProc_do_keyup
    jmp   WndProc_defproc

WndProc_do_paint:
    movq  %rdi, %rcx                # hWnd
    leaq  ps_buf(%rip), %rdx        # &PAINTSTRUCT
    call  BeginPaint                # returns HDC in RAX

    movq  %rax, %rdx                # HDC
    movq  %rdi, %rcx                # hWnd
    call  chip8_render_window       # render CHIP-8 framebuffer

    movq  %rdi, %rcx
    leaq  ps_buf(%rip), %rdx
    call  EndPaint

    xorl  %eax, %eax
    jmp   WndProc_ret

WndProc_do_destroy:
    # CHIP-8 sound may be playing, so force stop it first
    call  chip8_stop_beep

    # Kill the timer
    movq  hWndMain(%rip), %rcx
    movl  $TIMER_ID_STEP, %edx
    call  KillTimer

    # Post WM_QUIT
    xorl  %ecx, %ecx
    call  PostQuitMessage

    xorl  %eax, %eax
    jmp   WndProc_ret

WndProc_do_timer:
    # On each timer tick:
    #   - Execute a small number of chip8_step()
    #   - Tick timers (delay/sound)
    #   - If framebuffer is dirty, invalidate window for repaint (with erase)
    movl  $8, %ecx                  # Execute ~8 instructions per tick
WndProc_timer_loop:
    call  chip8_step
    decl  %ecx
    jnz   WndProc_timer_loop

    call  chip8_tick_timers

    leaq  chip8_state(%rip), %rax
    movzbl OFF_DIRTY(%rax), %edx
    testl %edx, %edx
    jz    .WndProc_timer_no_redraw

    # InvalidateRect(hWndMain, NULL, TRUE)
    movq  hWndMain(%rip), %rcx
    xorl  %edx, %edx                # lpRect = NULL (entire client area)
    movl  $1, %r8d                  # bErase = TRUE
    call  InvalidateRect

.WndProc_timer_no_redraw:
    xorl  %eax, %eax
    jmp   WndProc_ret

WndProc_do_keydown:
    movl  %r10d, %eax               # VK code
    cmpl  $VK_ESCAPE, %eax
    je    WndProc_do_destroy        # ESC -> close application

    call  map_key
    cmpl  $-1, %ecx
    je    WndProc_defproc           # unmapped key -> default processing

    movl  %ecx, %ecx                # key (0..15)
    movl  $1, %edx                  # pressed = 1
    call  chip8_set_key

    xorl  %eax, %eax
    jmp   WndProc_ret

WndProc_do_keyup:
    movl  %r10d, %eax               # VK code
    call  map_key
    cmpl  $-1, %ecx
    je    WndProc_defproc

    movl  %ecx, %ecx
    xorl  %edx, %edx                # pressed = 0
    call  chip8_set_key

    xorl  %eax, %eax
    jmp   WndProc_ret

WndProc_defproc:
    # Delegate unhandled messages to DefWindowProcA
    movq  %rdi, %rcx    # hWnd
    movq  %rsi, %rdx    # msg
    movq  %r10, %r8     # wParam
    movq  %r11, %r9     # lParam
    call  DefWindowProcA
    jmp   WndProc_ret

WndProc_ret:
    # Restore non-volatile registers and epilogue
    movq  -24(%rbp), %rbx
    movq  -16(%rbp), %rsi
    movq  -8(%rbp),  %rdi

    addq  $64, %rsp
    popq  %rbp
    ret


# ============================================================================  
# Sound helpers (no separate thread)
#
# chip8_start_beep:
# - If OFF_SOUND > 0 and no sound is playing,
#   just start PlaySoundA on the pre-rendered CDP1802 beep WAV.
#
# chip8_stop_beep:
# - If currently playing, stop it with PlaySoundA(NULL, NULL, 0).
#
# Only called from chip8_tick_timers() and WndProc_do_destroy().
# chip8_sound_on_flag tracks "already playing" state.
# ============================================================================  
chip8_start_beep:
    pushq %rbp
    movq  %rsp, %rbp
    subq  $32, %rsp                 # shadow space for PlaySoundA

    # If already playing, do nothing
    movzbl chip8_sound_on_flag(%rip), %eax
    testb %al, %al
    jnz   .Lcsb_done

    movb  $1, chip8_sound_on_flag(%rip)

    # PlaySoundA(chip8_beep_wav, NULL,
    #            SND_ASYNC | SND_MEMORY | SND_NODEFAULT | SND_LOOP);
    leaq  chip8_beep_wav(%rip), %rcx   # pszSound (memory)
    xorl  %edx, %edx                   # hmod = NULL
    movl  $(SND_ASYNC|SND_MEMORY|SND_NODEFAULT|SND_LOOP), %r8d
    call  PlaySoundA

.Lcsb_done:
    addq  $32, %rsp
    popq  %rbp
    ret

chip8_stop_beep:
    pushq %rbp
    movq  %rsp, %rbp
    subq  $32, %rsp                   # shadow space for PlaySoundA

    # If it's already off, do nothing
    movzbl chip8_sound_on_flag(%rip), %eax
    testb %al, %al
    jz    .Lctb_done

    movb  $0, chip8_sound_on_flag(%rip)

    # PlaySoundA(NULL, NULL, 0); -> Stops the current sound
    xorl  %ecx, %ecx
    xorl  %edx, %edx
    xorl  %r8d, %r8d
    call  PlaySoundA

.Lctb_done:
    addq  $32, %rsp
    popq  %rbp
    ret


# ============================================================================  
# main(int argc, char** argv)
#
# Windows x64:
#   RCX = argc
#   RDX = argv
#
# Responsibilities:
#   - Validate CLI arguments and store ROM filename
#   - Initialize CHIP-8 state and load ROM
#   - Register window class and create main window
#   - Create GDI brushes
#   - Set timer for CPU stepping
#   - Run GetMessage-based message loop
# ============================================================================  
main:
    pushq %rbp
    movq  %rsp, %rbp
    subq  $32, %rsp          # Shadow space

    movl  %ecx, %r8d         # R8D = argc
    movq  %rdx, %r9          # R9  = argv

    # If argc < 2, print usage and exit(1)
    cmpl  $2, %r8d
    jge   .Lm_have_arg
    leaq  fmt_usage(%rip), %rcx
    xorl  %eax, %eax
    call  printf
    movl  $1, %eax
    jmp   .Lm_exit

.Lm_have_arg:
    # argv[1] -> rom_filename
    movq  %r9, %rax
    movq  8(%rax), %rdx
    movq  %rdx, rom_filename(%rip)

    # Print "Loaded ROM: %s\n"
    leaq  fmt_loaded(%rip), %rcx
    movq  rom_filename(%rip), %rdx
    xorl  %eax, %eax
    call  printf

    # Initialize CHIP-8 state (also builds CDP1802-based beep PCM)
    call  chip8_init

    # Load ROM into memory
    movq  rom_filename(%rip), %rcx
    call  load_rom

    # Debug: print "After init+load"
    leaq  fmt_after_init(%rip), %rcx
    xorl  %eax, %eax
    call  printf

    # hInstance = GetModuleHandleA(NULL)
    xorl  %ecx, %ecx
    call  GetModuleHandleA
    movq  %rax, hInstance(%rip)

    # Create brushes for off/on pixels
    movl  $BLACK_RGB, %ecx
    call  CreateSolidBrush
    movq  %rax, hBrushOff(%rip)

    movl  $WHITE_RGB, %ecx
    call  CreateSolidBrush
    movq  %rax, hBrushOn(%rip)

    # ------------------------------------------------------------------------
    # Register window class (WNDCLASSEX)
    # ------------------------------------------------------------------------
    leaq  wcex_buf(%rip), %rdi
    movl  $80, 0(%rdi)                      # cbSize = sizeof(WNDCLASSEX)
    movl  $(CS_HREDRAW|CS_VREDRAW), 4(%rdi) # style
    leaq  WndProc(%rip), %rax
    movq  %rax, 8(%rdi)                     # lpfnWndProc
    movl  $0, 16(%rdi)                      # cbClsExtra
    movl  $0, 20(%rdi)                      # cbWndExtra
    movq  hInstance(%rip), %rax
    movq  %rax, 24(%rdi)                    # hInstance
    movq  $0, 32(%rdi)                      # hIcon
    movq  $0, 40(%rdi)                      # hCursor
    movq  hBrushOff(%rip), %rax
    movq  %rax, 48(%rdi)                    # hbrBackground
    movq  $0, 56(%rdi)                      # lpszMenuName
    leaq  className(%rip), %rax
    movq  %rax, 64(%rdi)                    # lpszClassName
    movq  $0, 72(%rdi)                      # hIconSm

    movq  %rdi, %rcx
    call  RegisterClassExA

    # Debug: print RegisterClassExA return value
    leaq  fmt_regcls(%rip), %rcx
    movl  %eax, %edx
    xorl  %eax, %eax
    call  printf

    # ------------------------------------------------------------------------
    # Create main window with client area roughly matching 64x32 * SCALE
    # ------------------------------------------------------------------------
    movl  $0, %ecx                            # dwExStyle
    leaq  className(%rip), %rdx              # lpClassName
    leaq  windowTitle(%rip), %r8             # lpWindowName
    movl  $WS_OVERLAPPEDWINDOW, %r9d         # dwStyle

    subq  $96, %rsp                          # 32 shadow + 8*8 stack args
    movl  $CW_USEDEFAULT, 32(%rsp)           # x
    movl  $CW_USEDEFAULT, 40(%rsp)           # y
    movl  $(64*SCALE+16), 48(%rsp)           # width
    movl  $(32*SCALE+39), 56(%rsp)           # height
    movq  $0, 64(%rsp)                       # hWndParent
    movq  $0, 72(%rsp)                       # hMenu
    movq  hInstance(%rip), %rax
    movq  %rax, 80(%rsp)                     # hInstance
    movq  $0, 88(%rsp)                       # lpParam

    call  CreateWindowExA
    addq  $96, %rsp

    movq  %rax, hWndMain(%rip)

    # Debug: print hWndMain
    leaq  fmt_hwnd(%rip), %rcx
    movq  hWndMain(%rip), %rdx
    xorl  %eax, %eax
    call  printf

    # ShowWindow / UpdateWindow
    movq  hWndMain(%rip), %rcx
    movl  $SW_SHOWDEFAULT, %edx
    call  ShowWindow

    movq  hWndMain(%rip), %rcx
    call  UpdateWindow

    # SetTimer(hWndMain, TIMER_ID_STEP, TIMER_INTERVAL_MS, NULL)
    movq  hWndMain(%rip), %rcx
    movl  $TIMER_ID_STEP, %edx
    movl  $TIMER_INTERVAL_MS, %r8d
    xorl  %r9d, %r9d
    subq  $32, %rsp
    call  SetTimer
    addq  $32, %rsp

    # ------------------------------------------------------------------------
    # Main message loop using GetMessage
    # ------------------------------------------------------------------------
.Lm_msg_loop:
    leaq  msg_buf(%rip), %rcx
    xorl  %edx, %edx
    xorl  %r8d, %r8d
    xorl  %r9d, %r9d
    subq  $32, %rsp
    call  GetMessageA
    addq  $32, %rsp
    testl %eax, %eax
    jle   .Lm_quit                     # 0 or -1 -> exit loop

    leaq  msg_buf(%rip), %rcx
    call  TranslateMessage

    leaq  msg_buf(%rip), %rcx
    call  DispatchMessageA

    jmp   .Lm_msg_loop

.Lm_quit:
    # Destroy brushes
    movq  hBrushOn(%rip), %rcx
    testq %rcx, %rcx
    je    1f
    call  DeleteObject
1:
    movq  hBrushOff(%rip), %rcx
    testq %rcx, %rcx
    je    .Lm_no_brush
    call  DeleteObject
.Lm_no_brush:
    movl  $0, %eax                      # return code

.Lm_exit:
    addq  $32, %rsp
    popq  %rbp
    ret
