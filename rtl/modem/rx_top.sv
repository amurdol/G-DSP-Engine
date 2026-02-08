// ============================================================================
// G-DSP Engine — RX Subsystem Top-Level
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Integrates the complete receive chain:
//
//   rx_I/Q (from channel)
//      │
//      ▼
//   ┌────────────┐    ┌────────────┐    ┌────────────┐
//   │  Rx RRC    │──▶│  Gardner    │──▶│  Costas    │──▶ demod_I/Q
//   │  Matched   │    │  Timing    │    │  Carrier   │    demod_lock
//   │  Filter    │    │  Recovery  │    │  Recovery  │
//   └────────────┘    └────────────┘    └────────────┘
//     (sample rate)    (sample→symbol)   (symbol rate)
//
// Sub-modules:
//   1. rrc_filter  ×2   — Matched filtering (maximise SNR before sync).
//                          Reuses the same coefficient set as the Tx RRC.
//   2. gardner_ted      — NCO-based timing recovery with linear
//                          interpolation and Gardner TED (non data-aided).
//   3. costas_loop      — Decision-directed carrier recovery with
//                          sin/cos LUT rotator and PI loop filter.
//
// Interface:
//   Inputs  : rx_I, rx_Q, rx_valid  (noisy sample-rate data from channel)
//   Outputs : demod_I, demod_Q, demod_valid  (clean symbol-rate points)
//             demod_lock  (carrier loop lock indicator)
//
// Latency:
//   RRC (1 cycle) + Gardner (variable, ~4 per symbol) + Costas (2 cycles)
//   Total: group delay ≈ (NUM_TAPS−1)/2 = 16 samples + sync acquisition.
// ============================================================================

module rx_top
    import gdsp_pkg::*;
(
    input  logic    clk,
    input  logic    rst_n,

    // --- Channel output (noisy, sample rate) ---
    input  sample_t rx_I,           // Noisy I (Q1.11)
    input  sample_t rx_Q,           // Noisy Q (Q1.11)
    input  logic    rx_valid,       // Sample-rate valid strobe

    // --- Demodulated output (symbol rate) ---
    output sample_t demod_I,        // De-rotated I (Q1.11)
    output sample_t demod_Q,        // De-rotated Q (Q1.11)
    output logic    demod_valid,    // Symbol-rate valid strobe
    output logic    demod_lock      // Costas loop lock indicator
);

    // ====================================================================
    // 1. Matched Filter — Rx RRC (I and Q channels)
    //
    //   Identical to the Tx pulse-shaping filter.  The cascade
    //   h_tx ⊛ h_rx = raised cosine, achieving zero-ISI at optimal
    //   sampling instants and maximising output SNR.
    // ====================================================================
    sample_t mf_I, mf_Q;
    logic    mf_I_valid, mf_Q_valid;

    rrc_filter u_rrc_rx_I (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (rx_I),
        .din_valid  (rx_valid),
        .dout       (mf_I),
        .dout_valid (mf_I_valid)
    );

    rrc_filter u_rrc_rx_Q (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (rx_Q),
        .din_valid  (rx_valid),
        .dout       (mf_Q),
        .dout_valid (mf_Q_valid)
    );

    // ====================================================================
    // 1b. Gain Compensation
    //
    //   The cascade of two RRC filters (TX + RX) has a peak gain of
    //   ||h_rrc||² ≈ 0.7095 instead of 1.0.  We compensate by
    //   multiplying by 1/0.7095 ≈ 1443/1024.  This restores the
    //   output constellation to full-scale QAM levels.
    //
    //   2 extra multipliers (12×12 = 24-bit) at sample rate.
    // ====================================================================
    localparam signed [DATA_WIDTH-1:0] GAIN_CORR = 12'sd1443; // ≈ 1.4094 × 1024
    localparam int GAIN_SHIFT = 10;

    function automatic sample_t gain_sat(input logic signed [PRODUCT_WIDTH-1:0] prod);
        logic signed [PRODUCT_WIDTH-GAIN_SHIFT-1:0] shifted;
        shifted = prod >>> GAIN_SHIFT;
        if (shifted > 2047)
            gain_sat = 12'sd2047;
        else if (shifted < -2048)
            gain_sat = -12'sd2048;
        else
            gain_sat = shifted[DATA_WIDTH-1:0];
    endfunction

    wire signed [PRODUCT_WIDTH-1:0] gc_prod_I = mf_I * GAIN_CORR;
    wire signed [PRODUCT_WIDTH-1:0] gc_prod_Q = mf_Q * GAIN_CORR;

    sample_t gc_I, gc_Q;
    assign gc_I = gain_sat(gc_prod_I);
    assign gc_Q = gain_sat(gc_prod_Q);

    // ====================================================================
    // 2. Timing Recovery — Gardner TED
    //
    //   Decimates from sample rate (SPS=4) to symbol rate (1 SPS).
    //   Produces optimally timed I/Q prompts and a symbol strobe.
    // ====================================================================
    sample_t ted_I, ted_Q;
    logic    ted_strobe;

    gardner_ted u_gardner (
        .clk        (clk),
        .rst_n      (rst_n),
        .din_I      (gc_I),
        .din_Q      (gc_Q),
        .din_valid  (mf_I_valid),    // I and Q share the same valid
        .sym_I      (ted_I),
        .sym_Q      (ted_Q),
        .sym_strobe (ted_strobe)
    );

    // ====================================================================
    // 3. Carrier Recovery — Decision-Directed Costas Loop
    //
    //   De-rotates the symbol-rate constellation and tracks any
    //   residual phase/frequency offset.  Outputs the final
    //   demodulated I/Q plus a lock indicator.
    // ====================================================================
    costas_loop u_costas (
        .clk         (clk),
        .rst_n       (rst_n),
        .sym_I       (ted_I),
        .sym_Q       (ted_Q),
        .sym_strobe  (ted_strobe),
        .demod_I     (demod_I),
        .demod_Q     (demod_Q),
        .demod_valid (demod_valid),
        .demod_lock  (demod_lock)
    );

endmodule : rx_top
