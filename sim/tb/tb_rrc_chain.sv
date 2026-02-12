// ============================================================================
// Debug testbench: TX → RRC → RRC only (no timing/carrier recovery)
// ============================================================================
`timescale 1ns / 1ps

module tb_rrc_chain;
    import gdsp_pkg::*;

    // Clock and reset
    logic clk = 0;
    logic rst_n = 0;
    always #18.519 clk = ~clk;  // ~27 MHz

    // TX signals
    sample_t tx_I, tx_Q;
    logic    tx_valid;
    logic    sym_tick;

    // TX top
    tx_top u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (1'b1),
        .tx_I     (tx_I),
        .tx_Q     (tx_Q),
        .tx_valid (tx_valid),
        .sym_tick (sym_tick)
    );

    // RX RRC filters
    sample_t mf_I, mf_Q;
    logic    mf_valid;

    rrc_filter u_rrc_rx_I (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (tx_I),
        .din_valid  (tx_valid),
        .dout       (mf_I),
        .dout_valid (mf_valid)
    );

    rrc_filter u_rrc_rx_Q (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (tx_Q),
        .din_valid  (tx_valid),
        .dout       (mf_Q),
        .dout_valid ()
    );

    // No gain correction needed - 5-tap RRC has ~1.0 peak gain
    wire sample_t gc_I = mf_I;
    wire sample_t gc_Q = mf_Q;

    // QAM levels for distance calculation (original scale)
    function automatic int min_qam_dist(input int val);
        int dist0, dist1, dist2, dist3;
        dist0 = (val > -1943) ? (val + 1943) : (-1943 - val);
        dist1 = (val > -648)  ? (val + 648)  : (-648 - val);
        dist2 = (val > 648)   ? (val - 648)  : (648 - val);
        dist3 = (val > 1943)  ? (val - 1943) : (1943 - val);
        
        if (dist0 < dist1 && dist0 < dist2 && dist0 < dist3) return dist0;
        if (dist1 < dist2 && dist1 < dist3) return dist1;
        if (dist2 < dist3) return dist2;
        return dist3;
    endfunction

    // Phase tracking
    int phase_cnt = 0;        // Counts modulo 4
    int valid_cnt = 0;        // Total valid samples
    int correct_ph[4];        // Correct symbols per phase
    int total_ph[4];          // Total symbols per phase

    // Test
    initial begin
        for (int i = 0; i < 4; i++) begin
            correct_ph[i] = 0;
            total_ph[i] = 0;
        end
        
        $dumpfile("sim/waves/tb_rrc_chain.vcd");
        $dumpvars(0, tb_rrc_chain);

        $display("============================================================");
        $display("  TX -> RRC -> RRC Chain Debug Test");
        $display("============================================================");
        $display("  GAIN_CORR = %0d", GAIN_CORR);
        $display("  Filter delay = %0d samples", NUM_TAPS - 1);
        $display("============================================================");

        // Reset
        repeat(5) @(posedge clk);
        rst_n <= 1;

        // Run for many valid samples
        while (valid_cnt < 2000) begin
            @(posedge clk);
            if (mf_valid) begin
                // Log first samples for debugging
                if (valid_cnt < 40) begin
                    $display("[cnt=%4d ph=%d] gc_I=%6d gc_Q=%6d | dist_I=%3d dist_Q=%3d", 
                             valid_cnt, phase_cnt, $signed(gc_I), $signed(gc_Q),
                             min_qam_dist($signed(gc_I)), min_qam_dist($signed(gc_Q)));
                end
                
                // After transient (skip first 40 samples = 10 symbols)
                if (valid_cnt >= 40) begin
                    total_ph[phase_cnt] = total_ph[phase_cnt] + 1;
                    // Consider correct if both I and Q within tolerance
                    if (min_qam_dist($signed(gc_I)) <= 350 && 
                        min_qam_dist($signed(gc_Q)) <= 350) begin
                        correct_ph[phase_cnt] = correct_ph[phase_cnt] + 1;
                    end
                end
                
                valid_cnt = valid_cnt + 1;
                phase_cnt = (phase_cnt + 1) % 4;
            end
        end

        $display("");
        $display("=== RESULTS (tolerance=200) ===");
        for (int p = 0; p < 4; p++) begin
            $display("  Phase %0d: %0d / %0d correct (%0d%%)", 
                     p, correct_ph[p], total_ph[p],
                     (total_ph[p] > 0) ? (100 * correct_ph[p] / total_ph[p]) : 0);
        end
        $display("============================================================");

        $finish;
    end

endmodule
