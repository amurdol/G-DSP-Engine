// ============================================================================
// G-DSP Engine — System Top-Level
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Top-level integration for Sipeed Tang Nano 9K:
//
//   ┌─────────────────────────────────────────────────────────────────────┐
//   │  clk_27m (27 MHz)                                                   │
//   │      │                                                              │
//   │      ▼                                                              │
//   │  ┌───────┐   clk_dsp (27 MHz)                                       │
//   │  │ GW_PLL├──────────────────┐                                       │
//   │  │       │   clk_pixel (25.2 MHz, VGA 480p)                         │
//   │  │       ├────────────────┐ │                                       │
//   │  │       │   clk_serial (126 MHz)                                   │
//   │  │       ├──────────────┐ │ │                                       │
//   │  └───────┘              │ │ │                                       │
//   │                         │ │ │                                       │
//   │  ┌─────────┐  ┌─────────┴─┴─┴───────────────────────────────────┐   │
//   │  │         │  │ clk_dsp domain                                  │   │
//   │  │  Button │  │  tx_top → channel_top → rx_top                  │   │
//   │  │   S1    │──│    (PRBS→QAM→RRC→AWGN→RRC→Gardner→Costas)      │   │
//   │  │         │  │                                    ↓            │   │
//   │  └─────────┘  │                             demod_I/Q/valid     │   │
//   │               └──────────────────────────────────────┬──────────┘   │
//   │                                                      │              │
//   │               ┌──────────────────────────────────────┼──────────┐   │
//   │               │ clk_pixel domain                     ↓          │   │
//   │               │  constellation_renderer → hdmi_tx → TMDS       │   │
//   │               └────────────────────────────────────────────────┘   │
//   └─────────────────────────────────────────────────────────────────────┘
//
// Button S1 cycles noise_magnitude: 0 → 20 → 50 → 100 (repeat)
// LEDs[3:0] display current noise level (binary indicator)
// LEDs[5:4] show lock status and heartbeat
// ============================================================================

module gdsp_top
    import gdsp_pkg::*;
(
    input  logic        clk_27m,        // 27 MHz board oscillator
    input  logic        rst_n,          // Active-low reset (button S2)
    input  logic        btn_user,       // User button S1 (noise control)
    output logic [5:0]  led,            // Onboard LEDs (active-low)

    // --- HDMI TMDS output (differential via ELVDS_OBUF) ---
    output logic        tmds_clk_p,
    output logic        tmds_clk_n,
    output logic [2:0]  tmds_data_p,
    output logic [2:0]  tmds_data_n
);

    // ========================================================================
    // Clock Generation
    //
    // Architecture:
    //   clk_27m (27 MHz)
    //       │
    //       ├──────────────────────────────► clk_dsp (27 MHz, direct)
    //       │
    //       ▼
    //   ┌─────────┐   clk_serial (126 MHz)
    //   │Gowin_rPLL├────────────────────────► to HDMI serialiser
    //   │         │         │
    //   └─────────┘         ▼
    //               ┌────────────┐
    //               │Gowin_CLKDIV│  ÷5
    //               │            ├──────────► clk_pixel (25.2 MHz, VGA)
    //               └────────────┘
    //
    // ========================================================================
    logic clk_dsp;
    logic clk_pixel;
    logic clk_serial;
    logic pll_lock;

    // DSP clock = input clock directly (27 MHz)
    assign clk_dsp = clk_27m;

    // rPLL: 27 MHz → 126 MHz (clk_serial for VGA 480p TMDS DDR)
    Gowin_rPLL u_pll (
        .clkin  (clk_27m),
        .clkout (clk_serial),    // 126 MHz
        .lock   (pll_lock)
    );

    // CLKDIV: 126 MHz ÷ 5 → 25.2 MHz (VGA 480p pixel clock)
    Gowin_CLKDIV u_clkdiv (
        .hclkin (clk_serial),
        .resetn (pll_lock),      // Hold in reset until PLL locks
        .clkout (clk_pixel)      // 25.2 MHz
    );

    // Combined reset: external button AND PLL lock
    wire sys_rst_n = rst_n && pll_lock;

    // ========================================================================
    // Button Debouncer + Noise Level Cycler (S1)
    //
    // Debounce: ~20ms at 27 MHz ≈ 540,000 cycles → use 19-bit counter
    // Noise levels: 0 → 20 → 50 → 100 (cycle on press)
    // ========================================================================
    logic [18:0] debounce_cnt;
    logic        btn_sync0, btn_sync1, btn_stable, btn_prev;
    logic [1:0]  noise_sel;
    logic [NOISE_MAG_WIDTH-1:0] noise_magnitude;

    // Synchroniser
    always_ff @(posedge clk_dsp or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            btn_sync0 <= 1'b1;  // Default high (button released)
            btn_sync1 <= 1'b1;
        end else begin
            btn_sync0 <= btn_user;
            btn_sync1 <= btn_sync0;
        end
    end

    // Debounce counter
    always_ff @(posedge clk_dsp or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            debounce_cnt <= '0;
            btn_stable   <= 1'b1;
        end else begin
            if (btn_sync1 != btn_stable) begin
                if (debounce_cnt == 19'h7FFFF)
                    btn_stable <= btn_sync1;
                else
                    debounce_cnt <= debounce_cnt + 1'b1;
            end else begin
                debounce_cnt <= '0;
            end
        end
    end

    // Edge detect for button press (falling edge = button pressed)
    always_ff @(posedge clk_dsp or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            btn_prev  <= 1'b1;
            noise_sel <= 2'b00;
        end else begin
            btn_prev <= btn_stable;
            if (btn_prev && !btn_stable)  // Falling edge
                noise_sel <= noise_sel + 1'b1;
        end
    end

    // Noise magnitude lookup
    always_comb begin
        case (noise_sel)
            2'b00:   noise_magnitude = 8'd0;
            2'b01:   noise_magnitude = 8'd20;
            2'b10:   noise_magnitude = 8'd50;
            2'b11:   noise_magnitude = 8'd100;
            default: noise_magnitude = 8'd0;
        endcase
    end

    // ========================================================================
    // TX Subsystem
    // ========================================================================
    sample_t tx_I, tx_Q;
    logic    tx_valid;
    logic    sym_tick;

    tx_top u_tx (
        .clk      (clk_dsp),
        .rst_n    (sys_rst_n),
        .en       (1'b1),
        .tx_I     (tx_I),
        .tx_Q     (tx_Q),
        .tx_valid (tx_valid),
        .sym_tick (sym_tick)
    );

    // ========================================================================
    // AWGN Channel
    // ========================================================================
    sample_t ch_I, ch_Q;
    logic    ch_valid;

    channel_top u_channel (
        .clk             (clk_dsp),
        .rst_n           (sys_rst_n),
        .en              (1'b1),
        .tx_I            (tx_I),
        .tx_Q            (tx_Q),
        .tx_valid        (tx_valid),
        .noise_magnitude (noise_magnitude),
        .rx_I            (ch_I),
        .rx_Q            (ch_Q),
        .rx_valid        (ch_valid)
    );

    // ========================================================================
    // RX Subsystem
    // ========================================================================
    sample_t demod_I, demod_Q;
    logic    demod_valid;
    logic    demod_lock;

    rx_top u_rx (
        .clk         (clk_dsp),
        .rst_n       (sys_rst_n),
        .rx_I        (ch_I),
        .rx_Q        (ch_Q),
        .rx_valid    (ch_valid),
        .demod_I     (demod_I),
        .demod_Q     (demod_Q),
        .demod_valid (demod_valid),
        .demod_lock  (demod_lock)
    );

    // ========================================================================
    // Constellation Renderer (clk_pixel domain)
    //
    // sym_valid from DSP domain needs CDC — the renderer handles this
    // internally with a 2-FF synchroniser.
    // ========================================================================
    logic [23:0] rgb_pixel;
    logic        video_hsync, video_vsync, video_de;

    constellation_renderer u_renderer (
        .clk_pixel  (clk_pixel),
        .rst_n      (sys_rst_n),
        .sym_I      (demod_I),
        .sym_Q      (demod_Q),
        .sym_valid  (demod_valid),
        .rgb_pixel  (rgb_pixel),
        .hsync      (video_hsync),
        .vsync      (video_vsync),
        .de         (video_de)
    );

    // ========================================================================
    // HDMI Transmitter (TMDS encoding + serialisation)
    // ========================================================================
    hdmi_tx u_hdmi (
        .clk_pixel  (clk_pixel),
        .clk_serial (clk_serial),
        .rst_n      (sys_rst_n),
        .rgb        (rgb_pixel),
        .hsync      (video_hsync),
        .vsync      (video_vsync),
        .de         (video_de),
        .tmds_clk_p (tmds_clk_p),
        .tmds_clk_n (tmds_clk_n),
        .tmds_d_p   (tmds_data_p),
        .tmds_d_n   (tmds_data_n)
    );

    // ========================================================================
    // LED Indicators (active-low) - NO dependen de PLL lock para debug
    //
    // LED[0]: Heartbeat (~0.8 Hz blink) - usa rst_n directo
    // LED[1]: PLL lock status (lit = locked)
    // LED[2]: Costas lock indicator (lit = locked)
    // LED[3]: sys_rst_n status (lit = system running)
    // LED[4]: Noise level bit 0
    // LED[5]: Noise level bit 1
    // ========================================================================
    logic [24:0] heartbeat_cnt;

    // Heartbeat usa rst_n directo, NO sys_rst_n
    always_ff @(posedge clk_dsp or negedge rst_n) begin
        if (!rst_n)
            heartbeat_cnt <= '0;
        else
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
    end

    assign led[0] = ~heartbeat_cnt[24];   // Heartbeat (debe parpadear siempre)
    assign led[1] = ~pll_lock;            // PLL lock (diagnóstico crítico)
    assign led[2] = ~demod_lock;          // Costas lock
    assign led[3] = ~sys_rst_n;           // System running indicator
    assign led[4] = ~noise_sel[0];        // Noise level bit 0
    assign led[5] = ~noise_sel[1];        // Noise level bit 1

endmodule : gdsp_top

// ============================================================================
// Gowin IP Simulation Stubs
//
// These modules are ONLY for Icarus Verilog simulation.
// For Gowin synthesis, the actual IPs in src/gowin_rpll/ and src/gowin_clkdiv/
// are used instead.
// ============================================================================
`ifdef SIMULATION

module Gowin_rPLL (
    input  logic clkin,
    output logic clkout,
    output logic lock
);
    // Simulation model: generate 371.25 MHz from any input
    assign lock = 1'b1;

    // Generate clk_serial (371.25 MHz) — period 2.694 ns
    logic clk_ser_sim = 0;
    always #1.347 clk_ser_sim = ~clk_ser_sim;
    assign clkout = clk_ser_sim;
endmodule : Gowin_rPLL

module Gowin_CLKDIV (
    input  logic hclkin,
    input  logic resetn,
    output logic clkout
);
    // Simulation model: divide input by 5
    // 371.25 MHz / 5 = 74.25 MHz — period 13.468 ns
    logic clk_pix_sim = 0;
    always #6.734 clk_pix_sim = ~clk_pix_sim;
    assign clkout = resetn ? clk_pix_sim : 1'b0;
endmodule : Gowin_CLKDIV

`endif // SIMULATION
