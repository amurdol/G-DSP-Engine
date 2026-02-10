// ============================================================================
// G-DSP Engine — HDMI 480p60 Transmitter (DVI-compatible)
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Implements TMDS encoding and 10:1 serialisation for HDMI 640×480 @ 60 Hz.
// DVI-compatible (no audio, no InfoFrame packets — video only).
//
// Architecture:
//   1. TMDS 8b/10b Encoder (×3 for R, G, B channels)
//   2. 10:1 Serialiser using Gowin OSER10 primitive (×4 for D0, D1, D2, CLK)
//   3. LVDS Output Buffers using ELVDS_OBUF primitive
//
// Clocking:
//   clk_pixel  = 25.2 MHz (input, VGA 640×480@60Hz)
//   clk_serial = 126 MHz (5× pixel clock, from PLL)
//
// TMDS channels:
//   D0 (Blue)  = B[7:0], hsync, vsync (during blanking)
//   D1 (Green) = G[7:0], CTL0=0, CTL1=0 (during blanking)
//   D2 (Red)   = R[7:0], CTL2=0, CTL3=0 (during blanking)
//   CLK        = pixel clock (encoded as 0000011111)
// ============================================================================

module hdmi_tx (
    input  logic        clk_pixel,      // 25.2 MHz pixel clock (VGA 480p)
    input  logic        clk_serial,     // 126 MHz serial clock (5×)
    input  logic        rst_n,

    // Video input
    input  logic [23:0] rgb,            // R[23:16] G[15:8] B[7:0]
    input  logic        hsync,          // H-sync (active-high for 720p)
    input  logic        vsync,          // V-sync (active-high for 720p)
    input  logic        de,             // Data enable (active video)

    // TMDS outputs (differential pairs via ELVDS_OBUF)
    output logic        tmds_clk_p,
    output logic        tmds_clk_n,
    output logic [2:0]  tmds_d_p,
    output logic [2:0]  tmds_d_n
);

    // ========================================================================
    // TMDS 8b/10b Encoder
    //
    // During DE (active video): encode 8-bit RGB data
    // During blanking: encode control symbols (hsync/vsync on blue channel)
    //
    // Control encoding (4 symbols):
    //   CTL[1:0] = 00 → 1101010100
    //   CTL[1:0] = 01 → 0010101011
    //   CTL[1:0] = 10 → 0101010100
    //   CTL[1:0] = 11 → 1010101011
    //
    // For Blue channel: CTL[0]=hsync, CTL[1]=vsync
    // For Green/Red:    CTL[1:0]=00 (no auxiliary data)
    // ========================================================================

    // Control symbol lookup
    function automatic logic [9:0] tmds_ctrl_encode(input logic [1:0] ctl);
        case (ctl)
            2'b00:   return 10'b1101010100;
            2'b01:   return 10'b0010101011;
            2'b10:   return 10'b0101010100;
            2'b11:   return 10'b1010101011;
            default: return 10'b1101010100;
        endcase
    endfunction

    // TMDS 8b/10b data encoder with DC balance
    function automatic logic [9:0] tmds_data_encode(
        input logic [7:0] din,
        input logic signed [4:0] dc_bias
    );
        logic [3:0] n1_din;            // Number of 1s in din
        logic [8:0] q_m;               // Intermediate 9-bit code
        logic [3:0] n1_qm;             // Number of 1s in q_m[7:0]
        logic [3:0] n0_qm;             // Number of 0s in q_m[7:0]
        logic [9:0] q_out;

        // Count 1s in input
        n1_din = din[0] + din[1] + din[2] + din[3] +
                 din[4] + din[5] + din[6] + din[7];

        // Stage 1: XOR or XNOR encoding
        if ((n1_din > 4) || (n1_din == 4 && din[0] == 0)) begin
            // Use XNOR (q_m[8] = 0)
            q_m[0] = din[0];
            q_m[1] = q_m[0] ~^ din[1];
            q_m[2] = q_m[1] ~^ din[2];
            q_m[3] = q_m[2] ~^ din[3];
            q_m[4] = q_m[3] ~^ din[4];
            q_m[5] = q_m[4] ~^ din[5];
            q_m[6] = q_m[5] ~^ din[6];
            q_m[7] = q_m[6] ~^ din[7];
            q_m[8] = 1'b0;
        end else begin
            // Use XOR (q_m[8] = 1)
            q_m[0] = din[0];
            q_m[1] = q_m[0] ^ din[1];
            q_m[2] = q_m[1] ^ din[2];
            q_m[3] = q_m[2] ^ din[3];
            q_m[4] = q_m[3] ^ din[4];
            q_m[5] = q_m[4] ^ din[5];
            q_m[6] = q_m[5] ^ din[6];
            q_m[7] = q_m[6] ^ din[7];
            q_m[8] = 1'b1;
        end

        // Count 1s and 0s in q_m[7:0]
        n1_qm = q_m[0] + q_m[1] + q_m[2] + q_m[3] +
                q_m[4] + q_m[5] + q_m[6] + q_m[7];
        n0_qm = 8 - n1_qm;

        // Stage 2: Inversion decision for DC balance
        if ((dc_bias == 0) || (n1_qm == 4)) begin
            // Use q_m[8] to decide
            q_out[9] = ~q_m[8];
            q_out[8] = q_m[8];
            if (q_m[8])
                q_out[7:0] = q_m[7:0];
            else
                q_out[7:0] = ~q_m[7:0];
        end else if ((dc_bias > 0 && n1_qm > 4) ||
                     (dc_bias < 0 && n1_qm < 4)) begin
            // Invert
            q_out[9]   = 1'b1;
            q_out[8]   = q_m[8];
            q_out[7:0] = ~q_m[7:0];
        end else begin
            // Don't invert
            q_out[9]   = 1'b0;
            q_out[8]   = q_m[8];
            q_out[7:0] = q_m[7:0];
        end

        return q_out;
    endfunction

    // ========================================================================
    // Per-Channel TMDS Encoding with DC Bias Tracking
    // ========================================================================
    logic [9:0] tmds_blue, tmds_green, tmds_red;
    logic signed [4:0] dc_bias_b, dc_bias_g, dc_bias_r;

    // Helper to update DC bias
    function automatic logic signed [4:0] update_dc_bias(
        input logic signed [4:0] bias_in,
        input logic [9:0] q_out
    );
        logic [3:0] n1 = q_out[0] + q_out[1] + q_out[2] + q_out[3] +
                         q_out[4] + q_out[5] + q_out[6] + q_out[7];
        logic signed [4:0] delta;
        if (q_out[9])
            delta = 8 - 2*n1;
        else
            delta = 2*n1 - 8;
        // Adjust for XOR/XNOR bit
        if (q_out[9] == 0 && q_out[8] == 1)
            return bias_in + delta + 2;
        else if (q_out[9] == 1 && q_out[8] == 0)
            return bias_in + delta - 2;
        else
            return bias_in + delta;
    endfunction

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            tmds_blue  <= 10'b1101010100;  // CTL 00
            tmds_green <= 10'b1101010100;
            tmds_red   <= 10'b1101010100;
            dc_bias_b  <= '0;
            dc_bias_g  <= '0;
            dc_bias_r  <= '0;
        end else if (de) begin
            // Active video: encode RGB
            tmds_blue  <= tmds_data_encode(rgb[7:0],   dc_bias_b);
            tmds_green <= tmds_data_encode(rgb[15:8],  dc_bias_g);
            tmds_red   <= tmds_data_encode(rgb[23:16], dc_bias_r);
            dc_bias_b  <= update_dc_bias(dc_bias_b, tmds_data_encode(rgb[7:0],   dc_bias_b));
            dc_bias_g  <= update_dc_bias(dc_bias_g, tmds_data_encode(rgb[15:8],  dc_bias_g));
            dc_bias_r  <= update_dc_bias(dc_bias_r, tmds_data_encode(rgb[23:16], dc_bias_r));
        end else begin
            // Blanking: encode control symbols
            tmds_blue  <= tmds_ctrl_encode({vsync, hsync});
            tmds_green <= tmds_ctrl_encode(2'b00);
            tmds_red   <= tmds_ctrl_encode(2'b00);
            dc_bias_b  <= '0;
            dc_bias_g  <= '0;
            dc_bias_r  <= '0;
        end
    end

    // ========================================================================
    // Clock Channel (constant pattern 0000011111)
    // ========================================================================
    wire [9:0] tmds_clk = 10'b0000011111;

    // ========================================================================
    // 10:1 Serialiser using Gowin OSER10 Primitive
    //
    // OSER10 serialises 10 parallel bits to 1 serial output using DDR mode.
    // NOTE: GW1NR-9 doesn't support true 10:1 @ 252MHz, so we use 5:1 DDR.
    // This outputs 2 bits per clk_serial edge (DDR) = effective 10:1 at 126MHz.
    // ========================================================================
    
    logic ser_out_b, ser_out_g, ser_out_r, ser_out_clk;

    // OSER10 for Blue channel
    OSER10 oser_blue (
        .D0(tmds_blue[0]),
        .D1(tmds_blue[1]),
        .D2(tmds_blue[2]),
        .D3(tmds_blue[3]),
        .D4(tmds_blue[4]),
        .D5(tmds_blue[5]),
        .D6(tmds_blue[6]),
        .D7(tmds_blue[7]),
        .D8(tmds_blue[8]),
        .D9(tmds_blue[9]),
        .PCLK(clk_pixel),
        .FCLK(clk_serial),
        .RESET(~rst_n),
        .Q(ser_out_b)
    );

    // OSER10 for Green channel
    OSER10 oser_green (
        .D0(tmds_green[0]),
        .D1(tmds_green[1]),
        .D2(tmds_green[2]),
        .D3(tmds_green[3]),
        .D4(tmds_green[4]),
        .D5(tmds_green[5]),
        .D6(tmds_green[6]),
        .D7(tmds_green[7]),
        .D8(tmds_green[8]),
        .D9(tmds_green[9]),
        .PCLK(clk_pixel),
        .FCLK(clk_serial),
        .RESET(~rst_n),
        .Q(ser_out_g)
    );

    // OSER10 for Red channel
    OSER10 oser_red (
        .D0(tmds_red[0]),
        .D1(tmds_red[1]),
        .D2(tmds_red[2]),
        .D3(tmds_red[3]),
        .D4(tmds_red[4]),
        .D5(tmds_red[5]),
        .D6(tmds_red[6]),
        .D7(tmds_red[7]),
        .D8(tmds_red[8]),
        .D9(tmds_red[9]),
        .PCLK(clk_pixel),
        .FCLK(clk_serial),
        .RESET(~rst_n),
        .Q(ser_out_r)
    );

    // OSER10 for Clock channel
    OSER10 oser_clock (
        .D0(tmds_clk[0]),
        .D1(tmds_clk[1]),
        .D2(tmds_clk[2]),
        .D3(tmds_clk[3]),
        .D4(tmds_clk[4]),
        .D5(tmds_clk[5]),
        .D6(tmds_clk[6]),
        .D7(tmds_clk[7]),
        .D8(tmds_clk[8]),
        .D9(tmds_clk[9]),
        .PCLK(clk_pixel),
        .FCLK(clk_serial),
        .RESET(~rst_n),
        .Q(ser_out_clk)
    );

    // ========================================================================
    // ELVDS_OBUF for Differential Output (Tang Nano 9K — Sipeed official)
    // Instancias individuales para mapeo correcto de pines diferenciales
    // ========================================================================
    ELVDS_OBUF tmds_buf_clk (.I(ser_out_clk), .O(tmds_clk_p), .OB(tmds_clk_n));
    ELVDS_OBUF tmds_buf_d0  (.I(ser_out_b),   .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF tmds_buf_d1  (.I(ser_out_g),   .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF tmds_buf_d2  (.I(ser_out_r),   .O(tmds_d_p[2]), .OB(tmds_d_n[2]));

endmodule : hdmi_tx
