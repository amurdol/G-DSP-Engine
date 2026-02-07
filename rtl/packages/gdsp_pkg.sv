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
    parameter real ROLLOFF      = 0.25;          // RRC roll-off factor α

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
