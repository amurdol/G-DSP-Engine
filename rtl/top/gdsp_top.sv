// ============================================================================
// G-DSP Engine — Top-Level Stub
// ============================================================================
// This is a placeholder for the full system integration.
// Instantiates all sub-modules and connects clocking, data-path, and HDMI.
// ============================================================================

`include "../packages/gdsp_pkg.sv"

module gdsp_top
    import gdsp_pkg::*;
(
    input  logic        clk_27m,        // 27 MHz board oscillator
    input  logic        rst_n,          // Active-low reset (active button)

    // --- HDMI Output ---
    output logic        tmds_clk_p,
    output logic        tmds_clk_n,
    output logic [2:0]  tmds_data_p,
    output logic [2:0]  tmds_data_n,

    // --- PSRAM Interface ---
    output logic        psram_ce_n,
    output logic        psram_sclk,
    inout  wire  [3:0]  psram_sio,

    // --- Debug ---
    output logic [5:0]  led               // Onboard LEDs
);

    // -----------------------------------------------------------------------
    // Clock generation (PLL) — to be implemented in Phase 1
    // -----------------------------------------------------------------------
    logic clk_sys;      // System / DSP clock
    logic clk_pix;      // 74.25 MHz pixel clock
    logic clk_pix_5x;   // 371.25 MHz TMDS serial clock
    logic pll_locked;

    assign clk_sys = clk_27m;  // Temporary: use raw oscillator
    assign led     = 6'b0;

    // -----------------------------------------------------------------------
    // Future module instantiations:
    //   - bit_gen          (PRBS / LFSR bit source)
    //   - qam16_mapper     (Gray-coded 16-QAM)
    //   - rrc_tx_filter    (Transmit pulse shaping)
    //   - awgn_channel     (Box-Muller noise injection)
    //   - rrc_rx_filter    (Matched filter)
    //   - gardner_ted      (Timing error detector)
    //   - costas_loop      (Carrier recovery)
    //   - constellation_renderer  (HDMI visualisation)
    //   - hdmi_tx          (TMDS encoder + serialiser)
    //   - psram_ctrl       (Frame-buffer DMA)
    // -----------------------------------------------------------------------

endmodule : gdsp_top
