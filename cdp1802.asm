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
    #   - Q bit gates a fixed-frequency square-wave tone (CA555 timer)
    #       Q = 1 -> tone on
    #       Q = 0 -> silence
    #   - Phase accumulator oscillator for the fixed tone
    #   - Asymmetric duty cycle (≈ 2/3 ≈ 66.7%) to mimic 555 astable behaviour
    #   - Q rising edge (0->1) resets phase (555 retrigger-style)
    #   - 2-stage 1st-order low-pass filter ≈ speaker/RC response
    #   - Very-slow DC offset tracker (crude AC coupling / bias drift)
    #   - Returns unsigned 8-bit PCM sample 0..255 (128 ≈ "silence")
    #
    # NOTE:
    #   - cdp1802_tone_step is initialized from the *actual* COSMAC VIP
    #     555 astable RC network:
    #         R1 = 100 kΩ, R2 = 100 kΩ, C = 0.0047 µF
    #     giving:
    #         f_555 ≈ 1.44 / ((R1 + 2*R2) * C) ≈ 1021 Hz
    #     and for a 44.1 kHz sample rate:
    #         step = 2^32 * f_555 / sample_rate ≈ 0x05EDB21D
    #
    #     If you change the RC values or the audio sample rate, recompute:
    #
    #         // 555 astable:
    #         //   f = 1.44 / ((R1 + 2*R2) * C)
    #         // then:
    #         //   step = 2^32 * f / sample_rate;
    #
    #   - cdp1802_mcycles keeps a running count of CDP1802 machine cycles
    #     (most instructions = 2 cycles, long branches = 3 cycles).
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
    # 2-stage 1st-order low-pass filter state (moves around ~128)
    .globl cdp1802_lp_state
cdp1802_lp_state:
    .space 4                         # int, stage 1 LPF

    .globl cdp1802_lp_state2
cdp1802_lp_state2:
    .space 4                         # int, stage 2 LPF

    # DC offset tracker (for very slow bias drift / AC coupling)
    .globl cdp1802_dc_offset
cdp1802_dc_offset:
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

    # CDP1802 machine cycle counter (most ops = 2 cycles, LBR = 3 cycles)
    .globl cdp1802_mcycles
cdp1802_mcycles:
    .space 8                         # uint64 machine cycle counter

    # Previous Q state (for rising edge detection)
    .globl cdp1802_q_prev
cdp1802_q_prev:
    .space 1                         # 0/1, last Q value seen by audio

    # Optional: CDP1863-style tone frequency register (OUT 3)
    # (not yet used by the interpreter; reserved for expansion)
    .globl cdp1802_tone_frequency_reg
cdp1802_tone_frequency_reg:
    .space 1                         # 0..255 raw register
    .space 2                         # padding


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
    # Q = 0,1,0,1,... repeats -> for this VIP-style audio model, this will
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
    movl  $128, cdp1802_lp_state(%rip)   # stage 1
    movl  $128, cdp1802_lp_state2(%rip)  # stage 2

    # DC offset starts at mid-level
    movl  $128, cdp1802_dc_offset(%rip)

    # Tone oscillator
    movl  $0, cdp1802_tone_phase(%rip)

    # Default tone_step: ≈1.02 kHz (≈1.0 kHz) at 44.1 kHz sample rate
    #   Using actual COSMAC VIP values:
    #       R1 = 100 kΩ, R2 = 100 kΩ, C = 0.0047 µF
    #       f_555 ≈ 1.44 / ((R1 + 2*R2) * C) ≈ 1021 Hz
    #       step ≈ 2^32 * 1021 / 44100 ≈ 0x05EDB21D
    movl  $0x05EDB21D, cdp1802_tone_step(%rip)

    # RNG seed
    movl  $1, cdp1802_rng_state(%rip)

    # CDP1802 machine cycle counter
    movq  $0, cdp1802_mcycles(%rip)

    # Q previous state & tone frequency register
    movb  $0, cdp1802_q_prev(%rip)
    movb  $0, cdp1802_tone_frequency_reg(%rip)

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
#
# Machine cycle accounting (CDP1802 spec):
#   - Most instructions: 2 machine cycles
#   - Long branches (LBR): 3 machine cycles
#   cdp1802_mcycles accumulates these counts.
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
    addq  $2, cdp1802_mcycles(%rip)  # IDL: 2 machine cycles
    jmp   .OP_DONE

# 7A: REQ -----------------------------------------------------------
.OP_REQ:
    movb  $0, OFF_Q(%rbx)
    addq  $2, cdp1802_mcycles(%rip)  # REQ: 2 machine cycles
    jmp   .OP_DONE

# 7B: SEQ -----------------------------------------------------------
.OP_SEQ:
    movb  $1, OFF_Q(%rbx)
    addq  $2, cdp1802_mcycles(%rip)  # SEQ: 2 machine cycles
    jmp   .OP_DONE

# 30: BR (short unconditional branch) -------------------------------
.OP_BR:
    movzbl (%r13,%rdi,1), %eax       # imm
    movl  %edi, %edx
    andl  $0xFF00, %edx              # keep upper byte
    orl   %eax, %edx
    andl  $0xFFFF, %edx
    movl  %edx, %edi                 # new PC
    addq  $2, cdp1802_mcycles(%rip)  # BR: 2 machine cycles
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
    addq  $2, cdp1802_mcycles(%rip)  # BQ taken: 2 machine cycles
    jmp   .OP_DONE

.OP_BQ_NOTQ:
    incl  %edi
    andl  $0xFFFF, %edi
    addq  $2, cdp1802_mcycles(%rip)  # BQ not taken: 2 machine cycles
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
    addq  $2, cdp1802_mcycles(%rip)  # BNQ taken: 2 machine cycles
    jmp   .OP_DONE

.OP_BNQ_Q1:
    incl  %edi
    andl  $0xFFFF, %edi
    addq  $2, cdp1802_mcycles(%rip)  # BNQ not taken: 2 machine cycles
    jmp   .OP_DONE

# C0: LBR (long unconditional branch, 16-bit addr) -----------------
.OP_LBR:
    movzbl (%r13,%rdi,1), %eax        # high
    movzbl 1(%r13,%rdi,1), %edx       # low
    shll  $8, %eax
    orl   %edx, %eax
    andl  $0xFFFF, %eax
    movl  %eax, %edi                  # new PC
    addq  $3, cdp1802_mcycles(%rip)   # LBR: 3 machine cycles
    jmp   .OP_DONE

# F8: LDI (D = imm) -------------------------------------------------
.OP_LDI:
    movzbl (%r13,%rdi,1), %eax
    movb  %al, OFF_D(%rbx)
    incl  %edi
    andl  $0xFFFF, %edi
    addq  $2, cdp1802_mcycles(%rip)   # LDI: 2 machine cycles
    jmp   .OP_DONE

# Others: 1-byte NOP -----------------------------------------------
.OP_NOP:
    addq  $2, cdp1802_mcycles(%rip)   # Treat unknown as 2-cycle NOP
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
# 1) Run 1802 for steps_per_sample instruction steps
# 2) Detect Q rising edge (0->1) and reset tone phase on that edge
# 3) Read Q pin; if Q==1, generate a fixed-frequency square-wave tone
#    using a phase accumulator (555-style oscillator) with ≈2/3 duty.
#    If Q==0, use a slowly adapting DC offset (simulated AC coupling).
# 4) Apply 2-stage 1st-order low-pass filter: y += (x - y) >> 3 twice
# 5) Clamp to 0..255, slowly adapt DC offset, and return AL/EAX
# -----------------------------------------------------------------------------
cdp1802_audio_sample:
    pushq %rbp
    movq  %rsp, %rbp

    pushq %rbx
    pushq %rsi
    pushq %rdi

    # 1) Run 1802 for the requested number of instruction steps
    #    RCX = steps_per_sample as-is
    call  cdp1802_step

    # 2) Q rising edge detection for phase reset
    movzbl cdp1802_state+OFF_Q(%rip), %eax   # EAX = current Q (0/1)
    movzbl cdp1802_q_prev(%rip), %edx        # EDX = previous Q

    testl %edx, %edx
    jnz   .Lq_not_rising_candidate           # prev != 0 -> no 0->1
    testl %eax, %eax
    jz    .Lq_not_rising_candidate           # curr == 0 -> still 0

    # Q: 0 -> 1 rising edge -> reset 555 phase
    movl  $0, cdp1802_tone_phase(%rip)

.Lq_not_rising_candidate:
    movb  %al, cdp1802_q_prev(%rip)          # store current Q as previous

    # 3) Q gates a fixed-frequency tone (CA555-style)
    testl %eax, %eax
    jz    .Laudio_q_zero

    # Q == 1 -> advance phase and generate square wave with ≈2/3 duty
    movl  cdp1802_tone_phase(%rip), %ecx
    addl  cdp1802_tone_step(%rip), %ecx
    movl  %ecx, cdp1802_tone_phase(%rip)

    # Use top 10 bits of phase as a sawtooth 0..1023
    movl  %ecx, %ebx
    shrl  $22, %ebx               # keep upper 10 bits

    # Threshold at ≈2/3: 1023 * (2/3) ≈ 682
    cmpl  $682, %ebx
    jl    .Lraw_high
    movl  $0, %ebx                # low level
    jmp   .Lraw_ready

.Lraw_high:
    # High level approximates 555 output not reaching full Vcc.
    # For example, if the VIP is a 5 V system and the 555 output swings
    # roughly 0 V .. 3.3 V, the equivalent 8-bit amplitude is:
    #   255 * (3.3 / 5.0) ≈ 168
    movl  $168, %ebx              # "high" ≈ (Vhigh/Vcc) * 255
    jmp   .Lraw_ready

.Laudio_q_zero:
    # Q == 0 -> silence around slowly adapting DC offset
    movl  cdp1802_dc_offset(%rip), %ebx

.Lraw_ready:
    # 4) 2-stage 1st-order low-pass filter: y += (x - y) >> 3 twice
    #
    # Stage 1
    movl  cdp1802_lp_state(%rip), %esi   # y1
    movl  %ebx, %eax                     # x
    subl  %esi, %eax                     # (x - y1)
    sarl  $3, %eax                       # >>3 ≈ 1/8
    addl  %eax, %esi                     # y1 += ...
    movl  %esi, cdp1802_lp_state(%rip)   # store y1

    # Stage 2
    movl  cdp1802_lp_state2(%rip), %edi  # y2
    movl  %esi, %eax                     # x2 = y1
    subl  %edi, %eax                     # (x2 - y2)
    sarl  $3, %eax                       # >>3 ≈ 1/8
    addl  %eax, %edi                     # y2 += ...
    movl  %edi, cdp1802_lp_state2(%rip)  # store y2

    # 5) Clamp final output to 0..255
    cmpl  $0, %edi
    jge   .Llp_nonneg2
    xorl  %edi, %edi
    jmp   .Llp_clamped2

.Llp_nonneg2:
    cmpl  $255, %edi
    jle   .Llp_clamped2
    movl  $255, %edi

.Llp_clamped2:
    # Very-slow DC offset adaptation (crude AC coupling)
    #
    # dc += (sample - dc) >> 8
    movl  cdp1802_dc_offset(%rip), %eax   # eax = dc
    movl  %edi, %ebx                      # ebx = sample
    subl  %eax, %ebx                      # (sample - dc)
    sarl  $8, %ebx                        # very slow (1/256)
    addl  %ebx, %eax                      # dc += ...
    movl  %eax, cdp1802_dc_offset(%rip)   # store new dc

    movl  %edi, %eax                      # return sample in EAX (0..255)

    popq  %rdi
    popq  %rsi
    popq  %rbx
    popq  %rbp
    ret
