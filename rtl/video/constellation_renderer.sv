// ============================================================================
// G-DSP Engine — Constellation Renderer
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Renders the IQ constellation onto a 480p60 (VGA 640×480) video stream
// without external memory.  Each received symbol paints a 2×2 pixel dot at
// the corresponding (x,y) coordinate within a 256×256 plot area centered on
// the 640×480 frame.
//
// Mapping (Q1.11 → pixel):
//   px_x = 320 + (I >>> 4)    ← range [−2048..+2047] → [192..447] center
//   px_y = 240 − (Q >>> 4)    ← inverted Y axis (positive Q = up)
//
// The 2×2 dot is achieved by buffering the pixel coordinate and checking
// if the current scan position falls within ±1 of the buffered point.
//
// No framebuffer — symbols decay instantly (scan-line racing).  For a
// persistent trace, enable PSRAM framebuffer in a later phase.
// ============================================================================

module constellation_renderer
    import gdsp_pkg::*;
(
    input  logic        clk_pixel,      // 25.2 MHz pixel clock (VGA 480p)
    input  logic        rst_n,

    // ---- Symbol input (clk_dsp domain, synchronised outside) ----
    input  sample_t     sym_I,          // Demodulated I (Q1.11)
    input  sample_t     sym_Q,          // Demodulated Q (Q1.11)
    input  logic        sym_valid,      // Symbol strobe

    // ---- Video timing outputs ----
    output logic [23:0] rgb_pixel,      // R[23:16] G[15:8] B[7:0]
    output logic        hsync,
    output logic        vsync,
    output logic        de              // Data enable (active video)
);

    // ========================================================================
    // 480p60 VGA Timing Parameters (VESA DMT)
    // ========================================================================
    // Horizontal:   640 active + 16 fp + 96 sync + 48 bp = 800 total
    // Vertical:     480 active + 10 fp +  2 sync + 33 bp = 525 total
    // Pixel clock: 25.175 MHz (≈25.2 MHz from PLL)
    // ========================================================================
    localparam int H_ACTIVE  = 640;
    localparam int H_FP      = 16;
    localparam int H_SYNC    = 96;
    localparam int H_BP      = 48;
    localparam int H_TOTAL   = H_ACTIVE + H_FP + H_SYNC + H_BP;  // 800

    localparam int V_ACTIVE  = 480;
    localparam int V_FP      = 10;
    localparam int V_SYNC    = 2;
    localparam int V_BP      = 33;
    localparam int V_TOTAL   = V_ACTIVE + V_FP + V_SYNC + V_BP;  // 525

    // Plot area: 256×256 pixel square, centered on screen
    localparam int PLOT_SIZE   = 256;
    localparam int PLOT_X_MIN  = (H_ACTIVE - PLOT_SIZE) / 2;  // 192
    localparam int PLOT_X_MAX  = PLOT_X_MIN + PLOT_SIZE - 1;  // 447
    localparam int PLOT_Y_MIN  = (V_ACTIVE - PLOT_SIZE) / 2;  // 112
    localparam int PLOT_Y_MAX  = PLOT_Y_MIN + PLOT_SIZE - 1;  // 367

    // Plot center in pixel coordinates
    localparam int CENTER_X    = H_ACTIVE / 2;  // 320
    localparam int CENTER_Y    = V_ACTIVE / 2;  // 240

    // ========================================================================
    // Horizontal and Vertical Counters
    // ========================================================================
    logic [11:0] h_cnt;
    logic [10:0] v_cnt;

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= '0;
            v_cnt <= '0;
        end else begin
            if (h_cnt == H_TOTAL - 1) begin
                h_cnt <= '0;
                if (v_cnt == V_TOTAL - 1)
                    v_cnt <= '0;
                else
                    v_cnt <= v_cnt + 1'b1;
            end else begin
                h_cnt <= h_cnt + 1'b1;
            end
        end
    end

    // ========================================================================
    // Sync and DE Generation
    // ========================================================================
    // hsync: active during [H_ACTIVE + H_FP, H_ACTIVE + H_FP + H_SYNC - 1]
    // vsync: active during [V_ACTIVE + V_FP, V_ACTIVE + V_FP + V_SYNC - 1]
    // Both are active-LOW for VGA 480p (VESA standard).
    // ========================================================================
    wire h_sync_region = (h_cnt >= H_ACTIVE + H_FP) &&
                         (h_cnt <  H_ACTIVE + H_FP + H_SYNC);
    wire v_sync_region = (v_cnt >= V_ACTIVE + V_FP) &&
                         (v_cnt <  V_ACTIVE + V_FP + V_SYNC);

    wire h_active = (h_cnt < H_ACTIVE);
    wire v_active = (v_cnt < V_ACTIVE);

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            hsync <= 1'b0;
            vsync <= 1'b0;
            de    <= 1'b0;
        end else begin
            hsync <= h_sync_region;
            vsync <= v_sync_region;
            de    <= h_active && v_active;
        end
    end

    // ========================================================================
    // Symbol Coordinate Conversion (CDC — double-register sym_valid)
    //
    // sym_valid comes from clk_dsp domain (27 MHz).  We do a simple
    // 2-FF synchroniser for the strobe, then grab the coordinates.
    // This introduces ~3 pixel clocks of latency (negligible for display).
    // ========================================================================
    logic sym_valid_sync0, sym_valid_sync1, sym_valid_sync2;

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            sym_valid_sync0 <= 1'b0;
            sym_valid_sync1 <= 1'b0;
            sym_valid_sync2 <= 1'b0;
        end else begin
            sym_valid_sync0 <= sym_valid;
            sym_valid_sync1 <= sym_valid_sync0;
            sym_valid_sync2 <= sym_valid_sync1;
        end
    end

    wire sym_pulse = sym_valid_sync1 && !sym_valid_sync2;  // Rising edge

    // ========================================================================
    // I/Q Coordinate Buffers
    //
    // We buffer the last N symbols to allow persistence (multiple dots
    // on screen).  For simplicity, we use a small FIFO of 32 entries.
    // On each frame (vsync edge), the buffer is cleared to simulate decay.
    // ========================================================================
    localparam int MAX_DOTS = 64;
    logic [11:0] dot_x [0:MAX_DOTS-1];
    logic [10:0] dot_y [0:MAX_DOTS-1];
    logic [5:0]  dot_wr_ptr;
    logic        dot_valid [0:MAX_DOTS-1];

    // vsync edge detection for clearing
    logic vsync_d;
    wire  vsync_rise = vsync && !vsync_d;

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n)
            vsync_d <= 1'b0;
        else
            vsync_d <= vsync;
    end

    // Convert I/Q to pixel coords (clamped to plot area)
    // I maps to X: center_x + (I >>> 4) where I range [−2048,+2047] → [−128,+127]
    // Q maps to Y: center_y − (Q >>> 4) (inverted for screen coords)
    wire signed [12:0] scaled_I = {{1{sym_I[11]}}, sym_I} >>> 4;  // [−128,+127]
    wire signed [12:0] scaled_Q = {{1{sym_Q[11]}}, sym_Q} >>> 4;

    wire [11:0] new_x = CENTER_X + scaled_I[11:0];
    wire [10:0] new_y = CENTER_Y - scaled_Q[10:0];

    integer i;

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            dot_wr_ptr <= '0;
            for (i = 0; i < MAX_DOTS; i = i + 1) begin
                dot_x[i]     <= '0;
                dot_y[i]     <= '0;
                dot_valid[i] <= 1'b0;
            end
        end else if (vsync_rise) begin
            // Clear all dots at start of new frame (decay)
            for (i = 0; i < MAX_DOTS; i = i + 1)
                dot_valid[i] <= 1'b0;
            dot_wr_ptr <= '0;
        end else if (sym_pulse) begin
            // Store new dot
            dot_x[dot_wr_ptr]     <= new_x;
            dot_y[dot_wr_ptr]     <= new_y;
            dot_valid[dot_wr_ptr] <= 1'b1;
            dot_wr_ptr            <= dot_wr_ptr + 1'b1;
        end
    end

    // ========================================================================
    // Pixel Rendering — Check if current (h_cnt, v_cnt) matches any dot
    //
    // For 2×2 pixels, we check if abs(h_cnt - dot_x) <= 1 AND
    // abs(v_cnt - dot_y) <= 1.
    // ========================================================================
    logic pixel_hit;
    
    // Combinational check against all buffered dots
    always_comb begin
        pixel_hit = 1'b0;
        for (int j = 0; j < MAX_DOTS; j = j + 1) begin
            if (dot_valid[j]) begin
                // Check 2×2 region around dot center
                if ((h_cnt >= dot_x[j]) && (h_cnt < dot_x[j] + 2) &&
                    (v_cnt >= dot_y[j]) && (v_cnt < dot_y[j] + 2))
                    pixel_hit = 1'b1;
            end
        end
    end

    // ========================================================================
    // Background Grid (optional visual aid)
    //
    // Draw faint gray grid lines at plot boundaries and center axes.
    // ========================================================================
    wire in_plot = (h_cnt >= PLOT_X_MIN) && (h_cnt <= PLOT_X_MAX) &&
                   (v_cnt >= PLOT_Y_MIN) && (v_cnt <= PLOT_Y_MAX);

    wire on_grid_x = (h_cnt == PLOT_X_MIN) || (h_cnt == PLOT_X_MAX) ||
                     (h_cnt == CENTER_X);
    wire on_grid_y = (v_cnt == PLOT_Y_MIN) || (v_cnt == PLOT_Y_MAX) ||
                     (v_cnt == CENTER_Y);
    wire on_grid = in_plot && (on_grid_x || on_grid_y);

    // Quadrant division lines (±648 and ±1943 normalized levels → pixel)
    // For visual reference, mark the decision boundaries at ±1296/16 = ±81 pixels
    // (midpoint between ±648 and ±1943)
    localparam int BOUNDARY_OFFSET = 81;  // 1296 >> 4
    wire on_decision = in_plot && (
        (h_cnt == CENTER_X - BOUNDARY_OFFSET) ||
        (h_cnt == CENTER_X + BOUNDARY_OFFSET) ||
        (v_cnt == CENTER_Y - BOUNDARY_OFFSET) ||
        (v_cnt == CENTER_Y + BOUNDARY_OFFSET)
    );

    // ========================================================================
    // RGB Output
    // ========================================================================
    // Priority: symbol dot (white) > decision grid (dark gray) > 
    //           axis grid (gray) > background (black)
    // ========================================================================
    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            rgb_pixel <= 24'h000000;
        end else if (h_active && v_active) begin
            if (pixel_hit)
                rgb_pixel <= 24'hFFFFFF;         // White symbol dot
            else if (on_decision)
                rgb_pixel <= 24'h303030;         // Dark gray decision bounds
            else if (on_grid)
                rgb_pixel <= 24'h606060;         // Gray axis/border
            else if (in_plot)
                rgb_pixel <= 24'h101010;         // Very dark plot background
            else
                rgb_pixel <= 24'h000000;         // Black outside plot
        end else begin
            rgb_pixel <= 24'h000000;             // Blanking
        end
    end

endmodule : constellation_renderer
