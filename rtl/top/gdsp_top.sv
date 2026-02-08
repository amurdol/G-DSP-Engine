// ============================================================================
// G-DSP Engine — Top-Level (Synthesis Target)
// ============================================================================
// Integration for synthesis: TX chain + AWGN channel.
// LEDs show activity. HDMI and PSRAM stubbed for Phase 4.
// ============================================================================

module gdsp_top
    import gdsp_pkg::*;
(
    // System
    input  logic        clk_27m,        // 27 MHz board oscillator
    input  logic        rst_n,          // Active-low reset (button S1)
    input  logic        btn_user,       // User button S2

    // LEDs (active-low on Tang Nano 9K)
    output logic [5:0]  led,

    // HDMI (stub — Phase 4)
    output logic        tmds_clk_p,
    output logic        tmds_clk_n,
    output logic [2:0]  tmds_data_p,
    output logic [2:0]  tmds_data_n,

    // PSRAM (stub — Phase 4)
    output logic        psram_ce_n,
    output logic        psram_sclk,
    inout  wire  [3:0]  psram_sio
);

    // ========================================================================
    // Clock — use raw 27 MHz oscillator for now (PLL in Phase 4)
    // ========================================================================
    wire clk = clk_27m;

    // ========================================================================
    // Internal signals
    // ========================================================================
    logic                     sym_tick;
    logic [BITS_PER_SYM-1:0]  tx_bits;
    logic                     bits_valid;
    sample_t                  tx_I, tx_Q;
    logic                     mapper_valid;
    sample_t                  shaped_I, shaped_Q;
    logic                     shaped_valid;
    sample_t                  rx_I, rx_Q;
    logic                     rx_valid;

    // Noise magnitude — button S2 toggles low/high noise
    logic [7:0] noise_mag;
    logic       btn_sync_r1, btn_sync_r2;

    // Button synchroniser (2-FF metastability guard)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            btn_sync_r1 <= 1'b1;
            btn_sync_r2 <= 1'b1;
        end else begin
            btn_sync_r1 <= btn_user;
            btn_sync_r2 <= btn_sync_r1;
        end
    end

    assign noise_mag = btn_sync_r2 ? 8'd32 : 8'd128;  // Released=low / Pressed=high

    // ========================================================================
    // Symbol tick — 1 pulse every SPS (4) clock cycles
    // ========================================================================
    logic [1:0] sps_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            sps_cnt <= '0;
        else
            sps_cnt <= sps_cnt + 1'b1;
    end

    assign sym_tick = (sps_cnt == '0);

    // ========================================================================
    // TX Subsystem
    // ========================================================================

    bit_gen u_bit_gen (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (sym_tick),
        .bits_out (tx_bits),
        .valid    (bits_valid)
    );

    qam16_mapper u_mapper (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (bits_valid),
        .bits_in  (tx_bits),
        .I_out    (tx_I),
        .Q_out    (tx_Q),
        .valid    (mapper_valid)
    );

    rrc_filter u_rrc_tx_I (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (1'b1),
        .din      (mapper_valid ? tx_I : 12'sd0),
        .dout     (shaped_I),
        .valid    (shaped_valid)
    );

    rrc_filter u_rrc_tx_Q (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (1'b1),
        .din      (mapper_valid ? tx_Q : 12'sd0),
        .dout     (shaped_Q),
        .valid    ()
    );

    // ========================================================================
    // AWGN Channel
    // ========================================================================
    awgn_channel u_channel (
        .clk             (clk),
        .rst_n           (rst_n),
        .en              (shaped_valid),
        .tx_I            (shaped_I),
        .tx_Q            (shaped_Q),
        .noise_magnitude (noise_mag),
        .rx_I            (rx_I),
        .rx_Q            (rx_Q),
        .valid           (rx_valid)
    );

    // ========================================================================
    // LED Activity Indicators (active-low on Tang Nano 9K)
    // ========================================================================
    logic [24:0] heartbeat_cnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            heartbeat_cnt <= '0;
        else
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
    end

    assign led[0] = ~heartbeat_cnt[24];   // ~0.8 Hz heartbeat
    assign led[1] = ~sym_tick;
    assign led[2] = ~shaped_valid;
    assign led[3] = ~rx_valid;
    assign led[4] = btn_sync_r2;           // Pressed=low=LED on
    assign led[5] = 1'b1;                  // Off (reserved)

    // ========================================================================
    // HDMI Stub (Phase 4)
    // ========================================================================
    assign tmds_clk_p  = 1'b0;
    assign tmds_clk_n  = 1'b1;
    assign tmds_data_p = 3'b000;
    assign tmds_data_n = 3'b111;

    // ========================================================================
    // PSRAM Stub (Phase 4)
    // ========================================================================
    assign psram_ce_n = 1'b1;              // Deselected
    assign psram_sclk = 1'b0;
    assign psram_sio  = 4'bzzzz;           // High-Z

endmodule : gdsp_top
