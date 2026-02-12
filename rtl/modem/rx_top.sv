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
    // 1b. No Gain Compensation Needed
    //
    //   With 5-tap RRC filters, the cascade peak gain is ~1.0, so no
    //   compensation is required. Pass matched filter output directly.
    // ====================================================================
    wire sample_t gc_I = mf_I;
    wire sample_t gc_Q = mf_Q;

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
