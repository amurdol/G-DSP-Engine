// ============================================================================
// G-DSP Engine — Constellation Renderer Testbench
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Testbench for constellation_renderer module.
// Generates a complete VGA frame (640x480) with simulated 16-QAM symbols
// and exports RGB pixel data to CSV for visualization.
//
// Output: constellation_frame.csv with format x,y,r,g,b
// ============================================================================

`timescale 1ns / 1ps

module tb_constellation_renderer;

    // ========================================================================
    // Clock and Timing Parameters
    // ========================================================================
    // VGA 640x480 @ 60Hz: pixel clock = 25.175 MHz ≈ 39.72 ns period
    localparam real CLK_PERIOD_NS = 39.72;  // 25.175 MHz
    
    // VGA Timing (must match DUT)
    localparam int H_ACTIVE = 640;
    localparam int H_FP     = 16;
    localparam int H_SYNC   = 96;
    localparam int H_BP     = 48;
    localparam int H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;  // 800
    
    localparam int V_ACTIVE = 480;
    localparam int V_FP     = 10;
    localparam int V_SYNC   = 2;
    localparam int V_BP     = 33;
    localparam int V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;  // 525
    
    // Total pixels per frame
    localparam int PIXELS_PER_FRAME = H_TOTAL * V_TOTAL;  // 420,000
    
    // ========================================================================
    // 16-QAM Symbol Constants (Q1.11 format)
    // ========================================================================
    localparam logic signed [11:0] QAM_NEG3 = -12'sd1943;
    localparam logic signed [11:0] QAM_NEG1 = -12'sd648;
    localparam logic signed [11:0] QAM_POS1 =  12'sd648;
    localparam logic signed [11:0] QAM_POS3 =  12'sd1943;
    
    // ========================================================================
    // DUT Signals
    // ========================================================================
    logic        clk_pixel;
    logic        rst_n;
    
    // Symbol inputs
    logic signed [11:0] sym_I;
    logic signed [11:0] sym_Q;
    logic        sym_valid;
    
    // Video outputs
    logic [23:0] rgb_pixel;
    logic        hsync;
    logic        vsync;
    logic        de;
    
    // ========================================================================
    // Testbench Variables
    // ========================================================================
    integer csv_file;
    integer pixel_count;
    integer frame_count;
    integer symbol_idx;
    
    // Pixel position tracking
    integer h_pos, v_pos;
    
    // Symbol injection timing
    integer symbol_interval;
    integer symbol_timer;
    
    // 16 QAM symbols array (4x4 constellation)
    logic signed [11:0] qam_symbols_I [0:15];
    logic signed [11:0] qam_symbols_Q [0:15];
    
    // ========================================================================
    // Clock Generation (25.175 MHz)
    // ========================================================================
    initial begin
        clk_pixel = 1'b0;
        forever #(CLK_PERIOD_NS/2) clk_pixel = ~clk_pixel;
    end
    
    // ========================================================================
    // DUT Instantiation
    // ========================================================================
    constellation_renderer dut (
        .clk_pixel  (clk_pixel),
        .rst_n      (rst_n),
        .sym_I      (sym_I),
        .sym_Q      (sym_Q),
        .sym_valid  (sym_valid),
        .rgb_pixel  (rgb_pixel),
        .hsync      (hsync),
        .vsync      (vsync),
        .de         (de)
    );
    
    // ========================================================================
    // Initialize 16-QAM Symbol Table
    // ========================================================================
    // Gray-coded 16-QAM constellation:
    //   Q +3: 0000, 0001, 0011, 0010  (I: -3, -1, +1, +3)
    //   Q +1: 0100, 0101, 0111, 0110
    //   Q -1: 1100, 1101, 1111, 1110
    //   Q -3: 1000, 1001, 1011, 1010
    // ========================================================================
    initial begin
        // Row Q = +3
        qam_symbols_I[0]  = QAM_NEG3; qam_symbols_Q[0]  = QAM_POS3;  // 0000
        qam_symbols_I[1]  = QAM_NEG1; qam_symbols_Q[1]  = QAM_POS3;  // 0001
        qam_symbols_I[2]  = QAM_POS3; qam_symbols_Q[2]  = QAM_POS3;  // 0010
        qam_symbols_I[3]  = QAM_POS1; qam_symbols_Q[3]  = QAM_POS3;  // 0011
        
        // Row Q = +1
        qam_symbols_I[4]  = QAM_NEG3; qam_symbols_Q[4]  = QAM_POS1;  // 0100
        qam_symbols_I[5]  = QAM_NEG1; qam_symbols_Q[5]  = QAM_POS1;  // 0101
        qam_symbols_I[6]  = QAM_POS3; qam_symbols_Q[6]  = QAM_POS1;  // 0110
        qam_symbols_I[7]  = QAM_POS1; qam_symbols_Q[7]  = QAM_POS1;  // 0111
        
        // Row Q = -3
        qam_symbols_I[8]  = QAM_NEG3; qam_symbols_Q[8]  = QAM_NEG3;  // 1000
        qam_symbols_I[9]  = QAM_NEG1; qam_symbols_Q[9]  = QAM_NEG3;  // 1001
        qam_symbols_I[10] = QAM_POS3; qam_symbols_Q[10] = QAM_NEG3;  // 1010
        qam_symbols_I[11] = QAM_POS1; qam_symbols_Q[11] = QAM_NEG3;  // 1011
        
        // Row Q = -1
        qam_symbols_I[12] = QAM_NEG3; qam_symbols_Q[12] = QAM_NEG1;  // 1100
        qam_symbols_I[13] = QAM_NEG1; qam_symbols_Q[13] = QAM_NEG1;  // 1101
        qam_symbols_I[14] = QAM_POS3; qam_symbols_Q[14] = QAM_NEG1;  // 1110
        qam_symbols_I[15] = QAM_POS1; qam_symbols_Q[15] = QAM_NEG1;  // 1111
    end
    
    // ========================================================================
    // Symbol Injection Task
    // ========================================================================
    // Injects a symbol with ISI-like spread for realistic visualization.
    // Real hardware has ~20% ISI from the 5-tap RRC filter, causing symbols
    // to spread around ideal positions with Gaussian-like distribution.
    task automatic inject_symbol(input int idx, input int isi_spread);
        logic signed [11:0] noise_I, noise_Q;
        int rand_I, rand_Q;
        
        // Generate symmetric noise: sum of multiple randoms approximates Gaussian
        // This creates ISI-like spread around constellation points
        rand_I = ($random % (2*isi_spread+1)) - isi_spread;
        rand_Q = ($random % (2*isi_spread+1)) - isi_spread;
        
        // Add second term for more Gaussian-like distribution
        rand_I = rand_I + (($random % (isi_spread+1)) - isi_spread/2);
        rand_Q = rand_Q + (($random % (isi_spread+1)) - isi_spread/2);
        
        noise_I = rand_I;
        noise_Q = rand_Q;
        
        sym_I = qam_symbols_I[idx % 16] + noise_I;
        sym_Q = qam_symbols_Q[idx % 16] + noise_Q;
        sym_valid = 1'b1;
        
        @(posedge clk_pixel);
        sym_valid = 1'b0;
    endtask
    
    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        // Initialize signals
        rst_n = 1'b0;
        sym_I = 12'sd0;
        sym_Q = 12'sd0;
        sym_valid = 1'b0;
        pixel_count = 0;
        frame_count = 0;
        symbol_idx = 0;
        symbol_interval = 500;  // Inject symbol every 500 pixel clocks
        symbol_timer = 0;
        
        // Display simulation info
        $display("============================================================");
        $display("  Constellation Renderer Testbench");
        $display("============================================================");
        $display("  Resolution: %0d x %0d", H_ACTIVE, V_ACTIVE);
        $display("  Total frame: %0d x %0d = %0d pixels", H_TOTAL, V_TOTAL, PIXELS_PER_FRAME);
        $display("  Pixel clock period: %.2f ns (%.3f MHz)", CLK_PERIOD_NS, 1000.0/CLK_PERIOD_NS);
        $display("============================================================");
        
        // Open CSV file for output
        csv_file = $fopen("sim/vectors/constellation_frame.csv", "w");
        if (csv_file == 0) begin
            $display("ERROR: Could not open CSV file for writing!");
            $finish;
        end
        
        // Write CSV header
        $fwrite(csv_file, "x,y,r,g,b\n");
        
        // Apply reset
        $display("[%0t] Applying reset...", $time);
        repeat(10) @(posedge clk_pixel);
        rst_n = 1'b1;
        $display("[%0t] Reset released.", $time);
        
        // Wait for first vsync to align
        $display("[%0t] Waiting for vsync alignment...", $time);
        @(posedge vsync);
        @(negedge vsync);
        $display("[%0t] Frame start detected.", $time);
        
        // Inject initial symbols (all 16 QAM points)
        $display("[%0t] Injecting initial 16-QAM symbols...", $time);
        for (int i = 0; i < 16; i++) begin
            inject_symbol(i, 250);  // ISI spread (~15% of full scale)
            repeat(20) @(posedge clk_pixel);
        end
        
        // Simulate one complete frame while capturing pixels
        $display("[%0t] Capturing frame data to CSV...", $time);
        
        // ====================================================================
        // CRITICAL: Proper synchronization for pixel capture
        // ====================================================================
        // The DUT registers rgb_pixel on posedge clk_pixel. The value of
        // rgb_pixel AFTER posedge corresponds to the pixel at coordinates
        // (h_cnt-1, v_cnt) because h_cnt increments on the same edge.
        //
        // Strategy:
        // 1. Wait for vsync to end (frame start)
        // 2. Wait for de rising edge (first active pixel)
        // 3. Use negedge to sample stable values (mid-cycle)
        // 4. Track position using de transitions
        // ====================================================================
        
        // Wait for frame start
        @(posedge vsync);
        $display("[%0t] vsync detected, waiting for active video...", $time);
        
        // Wait for first active pixel (de rising edge)
        @(posedge de);
        $display("[%0t] Active video started.", $time);
        
        h_pos = 0;
        v_pos = 0;
        
        // Capture entire frame
        // Sample on NEGEDGE for stable data (half cycle after posedge update)
        while (v_pos < V_ACTIVE) begin
            @(negedge clk_pixel);
            
            // Inject symbols periodically
            symbol_timer = symbol_timer + 1;
            if (symbol_timer >= symbol_interval) begin
                symbol_timer = 0;
                fork
                    begin
                        @(posedge clk_pixel);
                        inject_symbol(symbol_idx, 300);
                        symbol_idx = (symbol_idx + 1) % 16;
                    end
                join_none
            end
            
            // Capture pixel when data is valid
            if (de) begin
                // Write pixel data to CSV
                $fwrite(csv_file, "%0d,%0d,%0d,%0d,%0d\n",
                        h_pos,
                        v_pos,
                        rgb_pixel[23:16],
                        rgb_pixel[15:8],
                        rgb_pixel[7:0]);
                
                pixel_count = pixel_count + 1;
                h_pos = h_pos + 1;
            end
            else begin
                // de went low - end of line or blanking
                if (h_pos > 0) begin
                    // End of active line, move to next
                    if ((v_pos % 48) == 0) begin
                        $display("[%0t] Line %0d / %0d (%0d%%)", 
                                 $time, v_pos, V_ACTIVE, (v_pos * 100) / V_ACTIVE);
                    end
                    h_pos = 0;
                    v_pos = v_pos + 1;
                end
            end
        end
        
        frame_count = frame_count + 1;
        
        // Close CSV file
        $fclose(csv_file);
        
        // Display summary
        $display("============================================================");
        $display("  Simulation Complete!");
        $display("============================================================");
        $display("  Frames captured: %0d", frame_count);
        $display("  Pixels written: %0d (expected: %0d)", pixel_count, H_ACTIVE * V_ACTIVE);
        $display("  Output file: constellation_frame.csv");
        $display("============================================================");
        
        // Run Python visualization script
        $display("\nTo visualize results, run:");
        $display("  python scripts/visualize_constellation.py");
        
        // End simulation
        repeat(100) @(posedge clk_pixel);
        $finish;
    end
    
    // ========================================================================
    // Timeout Watchdog
    // ========================================================================
    initial begin
        // Timeout after 50ms (enough for ~1.25 frames at 25MHz)
        #50_000_000;
        $display("ERROR: Simulation timeout!");
        $fclose(csv_file);
        $finish;
    end
    
    // ========================================================================
    // Optional: Generate VCD waveform
    // ========================================================================
    initial begin
        $dumpfile("sim/waves/tb_constellation_renderer.vcd");
        $dumpvars(0, tb_constellation_renderer);
    end

endmodule : tb_constellation_renderer
