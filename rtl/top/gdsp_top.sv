// ============================================================================
// G-DSP Engine — Top-Level Stub
// ============================================================================
// Placeholder for full system integration.
// Will be populated after all subsystem phases are complete.
//
// Intended instantiation order:
//   bit_gen → qam16_mapper → rrc_filter (TX) → channel_top →
//   rrc_filter (RX) → gardner_ted → costas_loop →
//   constellation_renderer → hdmi_tx
//
// Known constraints (discovered during synthesis test):
//   - Gowin requires SystemVerilog 2017 language mode
//   - SDC uses '#' comments, not '//'
//   - PSRAM is internal to GW1NR-9 SiP (no pin constraints)
//   - HDMI differential needs TLVDS_OBUF primitives (not plain ports)
//   - Package params treated as localparam by Gowin (harmless warning)
// ============================================================================

module gdsp_top
    import gdsp_pkg::*;
(
    input  logic        clk_27m,        // 27 MHz board oscillator
    input  logic        rst_n,          // Active-low reset (button S1)
    input  logic        btn_user,       // User button S2
    output logic [5:0]  led             // Onboard LEDs (active-low)
);

    // Stub: heartbeat LED only
    logic [24:0] cnt;
    always_ff @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) cnt <= '0;
        else        cnt <= cnt + 1'b1;
    end

    assign led[0]   = ~cnt[24];  // ~0.8 Hz blink
    assign led[5:1] = 5'b11111;  // Off

endmodule : gdsp_top
