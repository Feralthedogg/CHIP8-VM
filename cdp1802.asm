    .att_syntax prefix

    # =========================================================================
    # Minimal CDP1802 core + Audio path (COSMAC VIP-style beep)
    #
    # Public functions:
    #   void cdp1802_init(void);
    #   void cdp1802_load(const unsigned char *src,
    #                     unsigned short addr,
    #                     unsigned int len);
    #   void cdp1802_step(unsigned int steps);
    #   unsigned int  cdp1802_get_q(void);         # EAX = 0/1
    #   unsigned char cdp1802_audio_sample(unsigned int steps_per_sample);
    #
    # Audio model (VIP base hardware style):
    #   - Q bit gates a fixed-frequency square-wave tone (555 timer)
    #       Q = 1 → tone on
    #       Q = 0 → silence
    #   - Simple phase accumulator oscillator for the tone
    #   - 1st-order low-pass filter approximating speaker/RC response
    #   - Returns unsigned 8-bit PCM sample 0..255 (128 around "silence")
    #
    # NOTE: cdp1802_tone_step is initialized for ~2 kHz at 44.1 kHz sample rate.
    #       You can override it from C:
    #           extern unsigned int cdp1802_tone_step;
    #           cdp1802_tone_step = ...;    // new step value
    # =========================================================================

    .section .bss
    .align 16

    # State structure layout ---------------------------------------------------
    .equ OFF_R,   0                  # R0..R15 (16*2 bytes = 32)
    .equ OFF_D,   OFF_R + 32         # 8-bit D
    .equ OFF_DF,  OFF_D + 1          # 8-bit DF (unused here)
    .equ OFF_P,   OFF_DF + 1         # 8-bit P (PC register index 0..15)
    .equ OFF_X,   OFF_P + 1          # 8-bit X (unused)
    .equ OFF_Q,   OFF_X + 1          # 8-bit Q (0/1)
    .equ OFF_IE,  OFF_Q + 1          # interrupt enable (unused)
    .equ OFF_T,   OFF_IE + 1         # temp T (unused)
    .equ OFF_PAD, OFF_T + 1

    .equ CDP1802_STATE_SIZE, OFF_PAD

    .globl cdp1802_state
cdp1802_state:
    .space CDP1802_STATE_SIZE        # 1802 registers/flags

    .globl cdp1802_mem
cdp1802_mem:
    .space 65536                     # 64 KB memory

    # Audio state --------------------------------------------------------------
    # Simple 1st-order low-pass filter state (moves around ~128)
    .globl cdp1802_lp_state
cdp1802_lp_state:
    .space 4                         # int, initialized in cdp1802_init

    # RNG state (LCG) – available for other uses, no longer used in audio path
    .globl cdp1802_rng_state
cdp1802_rng_state:
    .space 4                         # int, initialized in cdp1802_init

    # Tone oscillator: Q gates a fixed-frequency square wave (VIP 555-style)
    .globl cdp1802_tone_phase
cdp1802_tone_phase:
    .space 4                         # uint32 phase accumulator

    .globl cdp1802_tone_step
cdp1802_tone_step:
    .space 4                         # uint32 step per sample (controls freq)


    .section .rodata
    .align 4

    # -------------------------------------------------------------------------
    # Test beep ROM
    #
    # 0000: 7A          ; REQ        -> Q = 0
    # 0001: C0 00 04    ; LBR 0004   -> jump to 0004
    # 0004: 7B          ; SEQ        -> Q = 1
    # 0005: C0 00 00    ; LBR 0000   -> jump to 0000
    #
    # Q = 0,1,0,1,... repeats → for this VIP-style audio model, this will
    # modulate the gated tone (tone only present when Q=1).
    # -------------------------------------------------------------------------
    .globl cdp1802_beep_rom
cdp1802_beep_rom:
    .byte 0x7A              # 0000: REQ
    .byte 0xC0,0x00,0x04    # 0001: LBR 0004
    .byte 0x7B              # 0004: SEQ
    .byte 0xC0,0x00,0x00    # 0005: LBR 0000
    .equ CDP1802_BEEP_ROM_SIZE, . - cdp1802_beep_rom


    .section .text
    .globl cdp1802_init
    .globl cdp1802_load
    .globl cdp1802_step
    .globl cdp1802_get_q
    .globl cdp1802_audio_sample

# Internal RNG ----------------------------------------------------------------
# static unsigned char cdp1802_rng_next(void);
#   AL = random(0..255)
cdp1802_rng_next:
    pushq %rbp
    movq  %rsp, %rbp

    movl  cdp1802_rng_state(%rip), %eax
    movl  $1103515245, %ecx
    imull %ecx, %eax
    addl  $12345, %eax
    movl  %eax, cdp1802_rng_state(%rip)

    shrl  $16, %eax
    andl  $0xFF, %eax        # AL = 0..255

    popq  %rbp
    ret


# -----------------------------------------------------------------------------
# void cdp1802_init(void)
#
# Initialize state structure / audio state.
# -----------------------------------------------------------------------------
cdp1802_init:
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx

    leaq  cdp1802_state(%rip), %rbx
    movl  $CDP1802_STATE_SIZE, %ecx
    xorl  %eax, %eax
    movq  %rbx, %rdi
.L1802_zero_state:
    movb  %al, (%rdi)
    incq  %rdi
    decl  %ecx
    jnz   .L1802_zero_state

    # Initialize audio state
    # LPF center around 128 (silence level for unsigned PCM)
    movl  $128, cdp1802_lp_state(%rip)

    # Tone oscillator
    movl  $0, cdp1802_tone_phase(%rip)

    # Default tone_step: ~2 kHz at 44.1 kHz sample rate
    # step = 2^32 * f / Fs ≈ 2^32 * 2000 / 44100 ≈ 0x0B9C2779
    movl  $0x0B9C2779, cdp1802_tone_step(%rip)

    # RNG seed
    movl  $1, cdp1802_rng_state(%rip)

    popq  %rbx
    popq  %rbp
    ret


# -----------------------------------------------------------------------------
# void cdp1802_load(const unsigned char *src,
#                   unsigned short addr,
#                   unsigned int len)
#
# RCX = src
# RDX = addr (lower 16 bits used)
# R8D = len
#
# src[0..len-1] -> cdp1802_mem[addr..addr+len-1]
# -----------------------------------------------------------------------------
cdp1802_load:
    pushq %rbp
    movq  %rsp, %rbp
    pushq %rbx
    pushq %rsi
    pushq %rdi

    movq  %rcx, %rsi              # src
    movzwl %dx, %eax              # addr (16-bit)
    leaq  cdp1802_mem(%rip), %rbx
    addq  %rax, %rbx
    movq  %rbx, %rdi              # dst
    movl  %r8d, %ecx              # len

.L1802_copy_loop:
    testl %ecx, %ecx
    jz    .L1802_copy_done
    movb  (%rsi), %al
    movb  %al, (%rdi)
    incq  %rsi
    incq  %rdi
    decl  %ecx
    jmp   .L1802_copy_loop

.L1802_copy_done:
    popq  %rdi
    popq  %rsi
    popq  %rbx
    popq  %rbp
    ret


# -----------------------------------------------------------------------------
# unsigned int cdp1802_get_q(void)
#
# Return Q flag as 0 or 1.
# -----------------------------------------------------------------------------
cdp1802_get_q:
    movzbl cdp1802_state+OFF_Q(%rip), %eax
    ret


# -----------------------------------------------------------------------------
# void cdp1802_step(unsigned int steps)
#
# RCX = steps
#
# Implemented instructions:
#   00  IDL     : do nothing
#   7A  REQ     : Q = 0
#   7B  SEQ     : Q = 1
#   30  BR      : short unconditional branch
#   31  BQ      : branch if Q == 1
#   39  BNQ     : branch if Q == 0
#   C0  LBR     : long unconditional branch (16-bit addr)
#   F8  LDI     : D = imm
#
# All others are treated as 1-byte NOP.
# -----------------------------------------------------------------------------
cdp1802_step:
    pushq %rbp
    movq  %rsp, %rbp

    pushq %rbx
    pushq %rsi
    pushq %rdi
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movl  %ecx, %r12d                # steps_remaining
    leaq  cdp1802_state(%rip), %rbx  # state*
    leaq  cdp1802_mem(%rip),   %r13  # mem*

.L1802_step_loop:
    testl %r12d, %r12d
    jz    .L1802_step_done

    # ---- Read P & PC ----
    movzbl OFF_P(%rbx), %eax
    andl  $0x0F, %eax
    movl  %eax, %r14d                # r14d = P index

    movl  %r14d, %ecx
    shll  $1, %ecx                   # index * 2
    movslq %ecx, %rcx

    movw  OFF_R(%rbx,%rcx,1), %dx    # DX = R[P]
    movzwl %dx, %edi                  # EDI = PC

    # ---- opcode fetch ----
    movzbl (%r13,%rdi,1), %r15d      # opcode
    incl  %edi
    andl  $0xFFFF, %edi              # PC++

    movl  %r15d, %eax                # EAX = opcode

    # ---- decode ----
    cmpl  $0x00, %eax
    je    .OP_IDL

    cmpl  $0x7A, %eax
    je    .OP_REQ

    cmpl  $0x7B, %eax
    je    .OP_SEQ

    cmpl  $0x30, %eax
    je    .OP_BR

    cmpl  $0x31, %eax
    je    .OP_BQ

    cmpl  $0x39, %eax
    je    .OP_BNQ

    cmpl  $0xC0, %eax
    je    .OP_LBR

    cmpl  $0xF8, %eax
    je    .OP_LDI

    jmp   .OP_NOP

# 00: IDL -----------------------------------------------------------
.OP_IDL:
    jmp   .OP_DONE

# 7A: REQ -----------------------------------------------------------
.OP_REQ:
    movb  $0, OFF_Q(%rbx)
    jmp   .OP_DONE

# 7B: SEQ -----------------------------------------------------------
.OP_SEQ:
    movb  $1, OFF_Q(%rbx)
    jmp   .OP_DONE

# 30: BR (short unconditional branch) -------------------------------
.OP_BR:
    movzbl (%r13,%rdi,1), %eax       # imm
    movl  %edi, %edx
    andl  $0xFF00, %edx              # keep upper byte
    orl   %eax, %edx
    andl  $0xFFFF, %edx
    movl  %edx, %edi                 # new PC
    jmp   .OP_DONE

# 31: BQ (branch if Q == 1) ----------------------------------------
.OP_BQ:
    movzbl OFF_Q(%rbx), %edx
    testl %edx, %edx
    jz    .OP_BQ_NOTQ

    movzbl (%r13,%rdi,1), %eax
    movl  %edi, %edx
    andl  $0xFF00, %edx
    orl   %eax, %edx
    andl  $0xFFFF, %edx
    movl  %edx, %edi
    jmp   .OP_DONE

.OP_BQ_NOTQ:
    incl  %edi
    andl  $0xFFFF, %edi
    jmp   .OP_DONE

# 39: BNQ (branch if Q == 0) ---------------------------------------
.OP_BNQ:
    movzbl OFF_Q(%rbx), %edx
    testl %edx, %edx
    jnz   .OP_BNQ_Q1

    movzbl (%r13,%rdi,1), %eax
    movl  %edi, %edx
    andl  $0xFF00, %edx
    orl   %eax, %edx
    andl  $0xFFFF, %edx
    movl  %edx, %edi
    jmp   .OP_DONE

.OP_BNQ_Q1:
    incl  %edi
    andl  $0xFFFF, %edi
    jmp   .OP_DONE

# C0: LBR (long unconditional branch, 16-bit addr) -----------------
.OP_LBR:
    movzbl (%r13,%rdi,1), %eax        # high
    movzbl 1(%r13,%rdi,1), %edx       # low
    shll  $8, %eax
    orl   %edx, %eax
    andl  $0xFFFF, %eax
    movl  %eax, %edi                  # new PC
    jmp   .OP_DONE

# F8: LDI (D = imm) -------------------------------------------------
.OP_LDI:
    movzbl (%r13,%rdi,1), %eax
    movb  %al, OFF_D(%rbx)
    incl  %edi
    andl  $0xFFFF, %edi
    jmp   .OP_DONE

# Others: 1-byte NOP -----------------------------------------------
.OP_NOP:
    jmp   .OP_DONE

# Common epilogue (commit PC + loop) -------------------------------
.OP_DONE:
    movl  %r14d, %ecx
    shll  $1, %ecx
    movslq %ecx, %rcx
    movw  %di, OFF_R(%rbx,%rcx,1)     # R[P] = new PC

    decl  %r12d
    jmp   .L1802_step_loop

.L1802_step_done:
    popq  %r15
    popq  %r14
    popq  %r13
    popq  %r12
    popq  %rdi
    popq  %rsi
    popq  %rbx
    popq  %rbp
    ret


# -----------------------------------------------------------------------------
# unsigned char cdp1802_audio_sample(unsigned int steps_per_sample)
#
# RCX = steps_per_sample
#
# 1) Run 1802 for steps_per_sample cycles
# 2) Read Q pin; if Q==1, generate a fixed-frequency square-wave tone
#    using a phase accumulator (555-style oscillator). If Q==0, output silence.
# 3) Apply 1st-order low-pass filter: y += (x - y) >> 3
# 4) Clamp to 0..255 and return AL/EAX
# -----------------------------------------------------------------------------
cdp1802_audio_sample:
    pushq %rbp
    movq  %rsp, %rbp

    pushq %rbx
    pushq %rsi
    pushq %rdi

    # 1) Run 1802
    #    RCX = steps_per_sample as-is
    call  cdp1802_step

    # 2) Q gates a fixed-frequency tone
    movzbl cdp1802_state+OFF_Q(%rip), %eax   # EAX = Q (0/1)
    testl %eax, %eax
    jz    .Laudio_q_zero

    # Q == 1 → advance phase and generate square wave from MSB
    movl  cdp1802_tone_phase(%rip), %ecx
    addl  cdp1802_tone_step(%rip), %ecx
    movl  %ecx, cdp1802_tone_phase(%rip)

    movl  %ecx, %ebx
    shrl  $31, %ebx               # use MSB as square wave
    testl %ebx, %ebx
    jz    .Lraw_low
    movl  $255, %ebx              # high level
    jmp   .Lraw_ready

.Lraw_low:
    movl  $0, %ebx                # low level
    jmp   .Lraw_ready

.Laudio_q_zero:
    # Q == 0 → silence around mid-level (128)
    movl  $128, %ebx

.Lraw_ready:
    # 3) 1st-order low-pass filter: y += (x - y) >> 3
    movl  cdp1802_lp_state(%rip), %esi   # y
    movl  %ebx, %eax                     # x
    subl  %esi, %eax                     # (x - y)
    sarl  $3, %eax                       # >>3 ≈ 1/8
    addl  %eax, %esi                     # y += ...

    # 4) Clamp filter state to 0..255
    cmpl  $0, %esi
    jge   .Llp_nonneg2
    xorl  %esi, %esi
    jmp   .Llp_clamped2

.Llp_nonneg2:
    cmpl  $255, %esi
    jle   .Llp_clamped2
    movl  $255, %esi

.Llp_clamped2:
    movl  %esi, cdp1802_lp_state(%rip)
    movl  %esi, %eax               # return sample in AL/EAX (0..255)

    popq  %rdi
    popq  %rsi
    popq  %rbx
    popq  %rbp
    ret
