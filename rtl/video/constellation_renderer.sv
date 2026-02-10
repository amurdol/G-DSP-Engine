// ============================================================================
// G-DSP Engine — Constellation Renderer
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Renders the IQ constellation onto a 480p60 (VGA 640×480) video stream.
// Each received symbol paints a 4×4 pixel dot.
//
// Mapping (Q1.11 → pixel coordinates):
//   px_x = 320 + (I >>> 3)    ← range [−2048..+2047] → [64..576]
//   px_y = 240 − (Q >>> 3)    ← range [−2048..+2047] → [-16..496] clipped
//
// Scale >>>3 (divide by 8) for both axes maintains square constellation.
// No framebuffer — symbols decay instantly (scan-line racing).
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

    // Plot center in pixel coordinates
    localparam int CENTER_X = H_ACTIVE / 2;  // 320
    localparam int CENTER_Y = V_ACTIVE / 2;  // 240

    // ========================================================================
    // Horizontal and Vertical Counters
    // ========================================================================
    logic [11:0] h_cnt;  // 0..799
    logic [10:0] v_cnt;  // 0..524

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

    // ========================================================================
    // ANAMORPHIC CORRECTION for 480p on 16:9 Displays
    // ========================================================================
    // Problem: 640×480 (4:3) → stretched to 1920×1080 (16:9) → rectangular
    // Solution: Apply 0.75× compression to X-axis before rendering
    //
    // Math: Monitor stretches X by 3.0× vs Y by 2.25× → ratio = 3/2.25 = 4/3
    //       To compensate: pre-compress X by 2.25/3 = 0.75 = 3/4
    //
    // Implementation (scaled to ±66px × ±88px display area):
    //   I → X: QAM outer symbols (±1943) → ±66px horizontal
    //          scaled_I = (I × 23 / 512) × 3/4 (anamorphic)
    //          Using shifts: 23 = 16+4+2+1, so x*23 = (x<<4)+(x<<2)+(x<<1)+x
    //          ±1943 → ±87px → ±65px after compression ≈ ±66px ✓
    //
    //   Q → Y: QAM outer symbols (±1943) → ±88px vertical
    //          scaled_Q = Q × 23 / 512
    //          ±1943 → ±87px ≈ ±88px ✓
    //
    // Result: Constellation fits perfectly in validated square area that
    //         appears as perfect square on 16:9 displays.
    // ========================================================================
    // Multiply by 23 using shifts and adds (no DSP blocks): x*23 = 16x+4x+2x+x
    wire signed [16:0] scaled_I_x23 = ($signed(sym_I) <<< 4) + ($signed(sym_I) <<< 2) + 
                                       ($signed(sym_I) <<< 1) + $signed(sym_I);
    wire signed [12:0] scaled_I_pre = (scaled_I_x23 + 256) >>> 9;  // ×23/512
    wire signed [12:0] scaled_I = (scaled_I_pre * 3 + 2) >>> 2;     // ×0.75 anamorphic
    
    wire signed [16:0] scaled_Q_x23 = ($signed(sym_Q) <<< 4) + ($signed(sym_Q) <<< 2) + 
                                       ($signed(sym_Q) <<< 1) + $signed(sym_Q);
    wire signed [12:0] scaled_Q = (scaled_Q_x23 + 256) >>> 9;       // ×23/512

    // Correctly handle signed arithmetic for coordinate conversion
    wire signed [12:0] x_coord = $signed({1'b0, CENTER_X}) + scaled_I;
    wire signed [12:0] y_coord = $signed({1'b0, CENTER_Y}) - scaled_Q;
    
    // Clip to screen boundaries [0, 639] × [0, 479]
    wire [11:0] new_x = (x_coord < 0) ? 12'd0 : 
                        (x_coord >= H_ACTIVE) ? (H_ACTIVE - 1) : 
                        x_coord[11:0];
    wire [10:0] new_y = (y_coord < 0) ? 11'd0 : 
                        (y_coord >= V_ACTIVE) ? (V_ACTIVE - 1) : 
                        y_coord[10:0];

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
    // For 4×4 pixels, we check if abs(h_cnt - dot_x) <= 2 AND
    // abs(v_cnt - dot_y) <= 2.
    // Color dots by quadrant for better visualization.
    // ========================================================================
    logic pixel_hit;
    logic [1:0] hit_quadrant;  // Which quadrant the hit dot is in
    
    // Combinational check against all buffered dots
    always_comb begin
        pixel_hit = 1'b0;
        hit_quadrant = 2'b00;
        for (int j = 0; j < MAX_DOTS; j = j + 1) begin
            if (dot_valid[j]) begin
                // Check 2×2 region around dot center (compact, prevents overlap)
                if ((h_cnt >= dot_x[j]) && (h_cnt < dot_x[j] + 2) &&
                    (v_cnt >= dot_y[j]) && (v_cnt < dot_y[j] + 2)) begin
                    pixel_hit = 1'b1;
                    // Determine quadrant based on dot position relative to center
                    hit_quadrant = {(dot_y[j] < CENTER_Y), (dot_x[j] >= CENTER_X)};
                    // Quadrant encoding: [Q above center?, I positive?]
                    // 2'b11 = Q1 (top-right: +I, +Q)
                    // 2'b10 = Q2 (top-left:  -I, +Q)
                    // 2'b00 = Q3 (bot-left:  -I, -Q)
                    // 2'b01 = Q4 (bot-right: +I, -Q)
                end
            end
        end
    end

    // ========================================================================
    // Background Grid (480p full screen with improved visibility)
    //
    // Draw enhanced grid with thick center axes, tick marks at QAM symbol
    // positions, and decision boundaries.
    // ========================================================================
    wire in_active_area = (h_cnt < H_ACTIVE) && (v_cnt < V_ACTIVE);

    // Center axes (1 pixel wide)
    wire on_axis_x = (h_cnt == CENTER_X) && (v_cnt < V_ACTIVE);
    wire on_axis_y = (v_cnt == CENTER_Y) && (h_cnt < H_ACTIVE);
    wire on_main_axis = in_active_area && (on_axis_x || on_axis_y);

    // Screen border (1 pixel)
    wire on_border = in_active_area && (
        (h_cnt == 0) || (h_cnt == H_ACTIVE - 1) ||
        (v_cnt == 0) || (v_cnt == V_ACTIVE - 1)
    );

    // Tick marks at 16-QAM symbol positions with anamorphic correction
    // QAM positions: I=±648, ±1943  Q=±648, ±1943
    // New scaling: ×23/512 → inner ±29px, outer ±87px
    // X-axis needs anamorphic correction (×0.75):
    localparam int TICK_INNER_X = 22;   // (648 * 23/512 * 3/4) ≈ 22px (anamorphic)
    localparam int TICK_OUTER_X = 66;   // (1943 * 23/512 * 3/4) ≈ 66px (anamorphic)
    // Y-axis uses standard scaling (no correction):
    localparam int TICK_INNER_Y = 29;   // (648 * 23/512) ≈ 29px
    localparam int TICK_OUTER_Y = 87;   // (1943 * 23/512) ≈ 87px
    localparam int TICK_LENGTH = 12;    // 12 pixels long
    
    wire on_tick_x = in_active_area && (
        // Horizontal ticks on Y-axis (marking I values) - use X correction
        ((v_cnt >= CENTER_Y - TICK_LENGTH) && (v_cnt <= CENTER_Y + TICK_LENGTH)) && (
            (h_cnt == CENTER_X - TICK_OUTER_X) ||
            (h_cnt == CENTER_X - TICK_INNER_X) ||
            (h_cnt == CENTER_X + TICK_INNER_X) ||
            (h_cnt == CENTER_X + TICK_OUTER_X)
        )
    );
    
    wire on_tick_y = in_active_area && (
        // Vertical ticks on X-axis (marking Q values) - use Y standard
        ((h_cnt >= CENTER_X - TICK_LENGTH) && (h_cnt <= CENTER_X + TICK_LENGTH)) && (
            (v_cnt == CENTER_Y - TICK_OUTER_Y) ||
            (v_cnt == CENTER_Y - TICK_INNER_Y) ||
            (v_cnt == CENTER_Y + TICK_INNER_Y) ||
            (v_cnt == CENTER_Y + TICK_OUTER_Y)
        )
    );

    wire on_ticks = on_tick_x || on_tick_y;

    // Decision boundary lines with anamorphic correction
    // Midpoint between inner and outer: (29+87)/2 = 58px base
    localparam int BOUNDARY_OFFSET_X = 44;   // (58 * 3/4) ≈ 44px (anamorphic)
    localparam int BOUNDARY_OFFSET_Y = 58;   // (29+87)/2 = 58px (no correction)
    wire on_decision = in_active_area && (
        (h_cnt == CENTER_X - BOUNDARY_OFFSET_X) ||
        (h_cnt == CENTER_X + BOUNDARY_OFFSET_X) ||
        (v_cnt == CENTER_Y - BOUNDARY_OFFSET_Y) ||
        (v_cnt == CENTER_Y + BOUNDARY_OFFSET_Y)
    );

    // Reference square for measuring anamorphic correction
    // This rectangle appears as a perfect square on 16:9 displays (VALIDATED)
    // Sized to match constellation display area with small margin
    localparam int SQUARE_SIZE_X = 70;  // ±70px (slightly larger than outer tick at 66px)
    localparam int SQUARE_SIZE_Y = 93;  // ±93px (slightly larger than outer tick at 87px)
    wire on_reference_square = in_active_area && (
        ((h_cnt == CENTER_X - SQUARE_SIZE_X) || (h_cnt == CENTER_X + SQUARE_SIZE_X)) &&
        (v_cnt >= CENTER_Y - SQUARE_SIZE_Y) && (v_cnt <= CENTER_Y + SQUARE_SIZE_Y)
    ) || (
        ((v_cnt == CENTER_Y - SQUARE_SIZE_Y) || (v_cnt == CENTER_Y + SQUARE_SIZE_Y)) &&
        (h_cnt >= CENTER_X - SQUARE_SIZE_X) && (h_cnt <= CENTER_X + SQUARE_SIZE_X)
    );

    // Test pattern: Dense grid for symmetry verification
    // Creates a filled square pattern to measure anamorphic correction
    // Area: 132×176 pixels (anamorphic 3:4 ratio) → appears as perfect square on 16:9
    // Size fits within screen bounds with margin: [254,386]×[152,328]
    localparam int TEST_SIZE_X = 132;  // ±66px horizontal (anamorphic, CENTER=320)
    localparam int TEST_SIZE_Y = 176;  // ±88px vertical (standard, CENTER=240)
    localparam int TEST_SPACING = 2;    // 2px spacing → ~66×88 points
    
    wire signed [12:0] h_offset = h_cnt - CENTER_X;
    wire signed [12:0] v_offset = v_cnt - CENTER_Y;
    
    // Check if within test area and on grid intersection
    wire in_test_area = (h_offset >= -TEST_SIZE_X) && (h_offset <= TEST_SIZE_X) &&
                        (v_offset >= -TEST_SIZE_Y) && (v_offset <= TEST_SIZE_Y);
    
    wire on_h_grid = (h_offset[0] == 1'b0);  // Every 2 pixels horizontally
    wire on_v_grid = (v_offset[0] == 1'b0);  // Every 2 pixels vertically
    
    wire on_test_pattern = in_active_area && in_test_area && on_h_grid && on_v_grid;

    // ========================================================================
    // RGB Output with Color-Coded Quadrants
    // ========================================================================
    // Q1 (top-right, +I+Q):    Cyan
    // Q2 (top-left,  -I+Q):    Green
    // Q3 (bot-left,  -I-Q):    Yellow
    // Q4 (bot-right, +I-Q):    Magenta
    // Test pattern: Dense 100×130 grid (white, for symmetry verification)
    // Decision bounds: dark blue
    // Reference square: white (for measuring aspect ratio)
    // Main axes: light gray
    // Ticks: medium gray
    // Border: dark gray
    // ========================================================================
    logic [23:0] dot_color;
    
    always_comb begin
        case (hit_quadrant)
            2'b11:   dot_color = 24'h00FFFF;  // Q1: Cyan
            2'b10:   dot_color = 24'h00FF00;  // Q2: Green
            2'b00:   dot_color = 24'hFFFF00;  // Q3: Yellow
            2'b01:   dot_color = 24'hFF00FF;  // Q4: Magenta
            default: dot_color = 24'hFFFFFF;  // Fallback: White
        endcase
    end
    
    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            rgb_pixel <= 24'h000000;
        end else if (h_active && v_active) begin
            if (pixel_hit)
                rgb_pixel <= dot_color;          // Colored symbol dot by quadrant
            else if (on_test_pattern)
                rgb_pixel <= 24'hFFFFFF;         // White constellation test points
            else if (on_main_axis)
                rgb_pixel <= 24'hA0A0A0;         // Light gray main axes
            else if (on_ticks)
                rgb_pixel <= 24'h707070;         // Medium gray tick marks
            else if (on_decision)
                rgb_pixel <= 24'h303080;         // Dark blue decision bounds
            else if (on_reference_square)
                rgb_pixel <= 24'hFFFFFF;         // White reference square
            else if (on_border)
                rgb_pixel <= 24'h505050;         // Dark gray border
            else
                rgb_pixel <= 24'h000000;         // Black background
        end else begin
            rgb_pixel <= 24'h000000;             // Blanking
        end
    end

endmodule : constellation_renderer
