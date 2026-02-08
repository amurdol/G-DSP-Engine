// ============================================================================
// G-DSP Engine — Global Parameters Package
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
// This package centralizes all fixed-point widths, DSP parameters, and
// system-level constants so that a single change propagates everywhere.
// ============================================================================

`ifndef GDSP_PKG_SV
`define GDSP_PKG_SV

package gdsp_pkg;

    // ========================================================================
    // Clock & Reset
    // ========================================================================
    parameter int CLK_FREQ_HZ   = 27_000_000;   // Tang Nano 9K oscillator
    parameter int HDMI_PIX_CLK  = 74_250_000;   // 720p @ 60 Hz pixel clock

    // ========================================================================
    // Fixed-Point Format  Q(INT_W).(FRAC_W)  — total = 1 + INT_W + FRAC_W
    //   Signed, two's complement.
    //   Default: Q1.11 → 13-bit signed (1 sign + 1 integer + 11 fractional)
    //   BUT we use 12-bit total (Q1.11 means 1 integer bit + 11 frac = 12 bits
    //   with implicit sign as MSB in two's complement).
    // ========================================================================
    parameter int DATA_WIDTH    = 12;            // Total bits per I or Q sample
    parameter int FRAC_BITS     = 11;            // Fractional bits
    parameter int INT_BITS      = 0;             // Integer bits (excl. sign)
    // Sign bit is implicit (MSB of two's complement)
    // Range: [−1.0, +1.0 − 2^{-11}]  ≈ [−1.0, +0.99951]

    // ========================================================================
    // Coefficient Format (for FIR filter taps)
    //   Same width to keep DSP multiplier inputs uniform.
    // ========================================================================
    parameter int COEFF_WIDTH   = 12;            // RRC tap coefficient width
    parameter int COEFF_FRAC    = 11;            // Fractional bits in coeffs

    // ========================================================================
    // FIR Accumulator
    //   product width = DATA_WIDTH + COEFF_WIDTH = 24
    //   accum  width  = product + ceil(log2(NUM_TAPS))
    // ========================================================================
    parameter int PRODUCT_WIDTH = DATA_WIDTH + COEFF_WIDTH;  // 24
    parameter int NUM_TAPS      = 33;            // RRC filter length (odd)
    parameter int ACCUM_EXTRA   = 6;             // ceil(log2(33)) = 6
    parameter int ACCUM_WIDTH   = PRODUCT_WIDTH + ACCUM_EXTRA; // 30

    // ========================================================================
    // 16-QAM Modulation
    // ========================================================================
    parameter int BITS_PER_SYM  = 4;             // log2(16)
    parameter int SPS           = 4;             // Samples per symbol
    parameter real ROLLOFF      = 0.25;          // RRC roll-off factor

    // 16-QAM normalised levels in Q1.11  (  {-3,-1,+1,+3} / sqrt(10)  )
    //   -3/sqrt(10) = -0.948683 -> round(-0.948683 * 2048) = -1943
    //   -1/sqrt(10) = -0.316228 -> round(-0.316228 * 2048) =  -648
    //   +1/sqrt(10) = +0.316228 -> round(+0.316228 * 2048) =  +648
    //   +3/sqrt(10) = +0.948683 -> round(+0.948683 * 2048) = +1943
    parameter signed [DATA_WIDTH-1:0] QAM_NEG3 = -12'sd1943;  // 12'sh869
    parameter signed [DATA_WIDTH-1:0] QAM_NEG1 = -12'sd648;   // 12'shD78
    parameter signed [DATA_WIDTH-1:0] QAM_POS1 =  12'sd648;   // 12'sh288
    parameter signed [DATA_WIDTH-1:0] QAM_POS3 =  12'sd1943;  // 12'sh797

    // ========================================================================
    // LFSR (PRBS-23) — bit generator
    //   Polynomial: x^23 + x^18 + 1  (ITU-T O.151)
    // ========================================================================
    parameter int LFSR_WIDTH    = 23;
    parameter int LFSR_TAP_A    = 23;            // MSB tap position
    parameter int LFSR_TAP_B    = 18;            // Second tap position

    // ========================================================================
    // AWGN Channel — Noise Generator
    //   Uses CLT (Central Limit Theorem) with 16 uniform LFSR sources.
    //   Each LFSR output is 12 bits; sum of 16 → 16-bit; shift/truncate → 12.
    //   noise_mag register: unsigned 8-bit scaling factor (0..255).
    //     Effective noise_rms ≈ noise_mag / 256 (in Q1.11 units).
    // ========================================================================
    parameter int NUM_LFSR_NOISE  = 16;            // LFSRs for CLT sum
    parameter int NOISE_MAG_WIDTH = 8;             // Bits for noise_magnitude register
    parameter int NOISE_SUM_WIDTH = DATA_WIDTH + 4; // 16 bits (12 + log2(16))
    parameter int NOISE_PROD_W    = NOISE_SUM_WIDTH + NOISE_MAG_WIDTH; // 24

    // LFSR polynomials — ALL verified primitive trinomials (x^n + x^k + 1).
    //   Sources: Xilinx XAPP052, P. Alfke (1996); New (2005) table.
    //   LFSRs 0–10: each a unique width (15..31, excluding non-trinomial n).
    //   LFSRs 11–15: reciprocal polynomials (x^n + x^{n-k} + 1) of earlier
    //     entries, providing distinct sequences of the SAME period.
    //   feedback = state[tap_a-1] ^ state[tap_b-1]
    //
    //   Idx  Poly                   Period
    //   ---  -----                  ------
    //    0   x^15 + x^14 + 1        32767
    //    1   x^17 + x^14 + 1       131071
    //    2   x^18 + x^11 + 1       262143
    //    3   x^20 + x^17 + 1      1048575
    //    4   x^21 + x^19 + 1      2097151
    //    5   x^22 + x^21 + 1      4194303
    //    6   x^23 + x^18 + 1      8388607  (ITU-T O.151)
    //    7   x^25 + x^22 + 1     33554431
    //    8   x^28 + x^25 + 1    268435455
    //    9   x^29 + x^27 + 1    536870911
    //   10   x^31 + x^28 + 1   2147483647
    //   11   x^15 + x^1  + 1       32767  (reciprocal of #0)
    //   12   x^17 + x^3  + 1      131071  (reciprocal of #1)
    //   13   x^20 + x^3  + 1     1048575  (reciprocal of #3)
    //   14   x^23 + x^5  + 1      8388607 (reciprocal of #6)
    //   15   x^25 + x^3  + 1     33554431 (reciprocal of #7)
    // LFSR polynomial lookup functions (iverilog-compatible)
    function automatic int noise_lfsr_width(input int idx);
        case (idx)
             0: return 15;   1: return 17;   2: return 18;   3: return 20;
             4: return 21;   5: return 22;   6: return 23;   7: return 25;
             8: return 28;   9: return 29;  10: return 31;  11: return 15;
            12: return 17;  13: return 20;  14: return 23;  15: return 25;
            default: return 23;
        endcase
    endfunction

    function automatic int noise_lfsr_tap_a(input int idx);
        case (idx)
             0: return 15;   1: return 17;   2: return 18;   3: return 20;
             4: return 21;   5: return 22;   6: return 23;   7: return 25;
             8: return 28;   9: return 29;  10: return 31;  11: return 15;
            12: return 17;  13: return 20;  14: return 23;  15: return 25;
            default: return 23;
        endcase
    endfunction

    function automatic int noise_lfsr_tap_b(input int idx);
        case (idx)
             0: return 14;   1: return 14;   2: return 11;   3: return 17;
             4: return 19;   5: return 21;   6: return 18;   7: return 22;
             8: return 25;   9: return 27;  10: return 28;  11: return  1;
            12: return  3;  13: return  3;  14: return  5;  15: return  3;
            default: return 18;
        endcase
    endfunction

    // ========================================================================
    // HDMI / Video
    // ========================================================================
    parameter int H_ACTIVE      = 1280;
    parameter int V_ACTIVE      = 720;
    parameter int H_TOTAL       = 1650;
    parameter int V_TOTAL       = 750;

    // ========================================================================
    // PSRAM (HyperRAM — 64 Mbit = 8 MB)
    // ========================================================================
    parameter int PSRAM_ADDR_W  = 23;            // 8M × 8 bit
    parameter int PSRAM_DATA_W  = 8;

    // ========================================================================
    // Type definitions
    // ========================================================================
    typedef logic signed [DATA_WIDTH-1:0]    sample_t;
    typedef logic signed [COEFF_WIDTH-1:0]   coeff_t;
    typedef logic signed [PRODUCT_WIDTH-1:0] product_t;
    typedef logic signed [ACCUM_WIDTH-1:0]   accum_t;

endpackage : gdsp_pkg

`endif // GDSP_PKG_SV
