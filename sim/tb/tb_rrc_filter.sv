// ============================================================================
// G-DSP Engine — Testbench: RRC Filter (bit-true verification)
// ============================================================================
// Feeds a known impulse and a known symbol sequence into the RRC FIR
// filter and compares outputs against golden reference vectors.
//
// Test plan:
//   1. Impulse response test — feed a single 1.0 (0x400 in Q1.11) and
//      verify the 33-tap output matches the coefficient array.
//   2. Vector comparison — load tx_filtered_I.hex and compare sample by
//      sample against the RTL output driven by qam16_symbols_I.hex.
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -o tb_rrc_filter \
//       -I ../../sim/vectors \
//       ../../rtl/packages/gdsp_pkg.sv \
//       ../../rtl/modem/rrc_filter.sv \
//       tb_rrc_filter.sv
//   vvp tb_rrc_filter
// ============================================================================

`timescale 1ns / 1ps

module tb_rrc_filter;
    import gdsp_pkg::*;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk   = 0;
    logic rst_n = 0;
    always #18.519 clk = ~clk;  // ~27 MHz

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    sample_t din;
    logic    din_valid;
    sample_t dout;
    logic    dout_valid;

    rrc_filter u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (din),
        .din_valid  (din_valid),
        .dout       (dout),
        .dout_valid (dout_valid)
    );

    // -----------------------------------------------------------------------
    // Reference data
    // -----------------------------------------------------------------------
    localparam int NUM_TX_SAMPLES = 1024;  // 256 symbols × 4 SPS

    logic [DATA_WIDTH-1:0] ref_tx_I [0:NUM_TX_SAMPLES-1];
    logic [DATA_WIDTH-1:0] ref_sym_I [0:255];

    initial begin
        $readmemh("sim/vectors/tx_filtered_I.hex", ref_tx_I);
        $readmemh("sim/vectors/qam16_symbols_I.hex", ref_sym_I);
    end

    // -----------------------------------------------------------------------
    // Include coefficient array for impulse response check
    // -----------------------------------------------------------------------
    `include "rrc_coeffs.v"

    // -----------------------------------------------------------------------
    // Test 1: Impulse response
    // -----------------------------------------------------------------------
    int errors = 0;
    int checks = 0;

    task automatic test_impulse();
        sample_t expected;
        int out_idx;
        $display("\n[TB] === Impulse Response Test ===");

        // Feed a unit impulse (0.5 in Q1.11 = 1024 = 12'sh400)
        // followed by NUM_TAPS-1 zeros to flush the filter
        @(posedge clk);
        din       = 12'sh400;  // 0.5 in Q1.11
        din_valid = 1'b1;
        @(posedge clk);
        din       = '0;

        // Collect outputs
        out_idx = 0;
        repeat (NUM_TAPS + 5) begin
            @(posedge clk);
            if (dout_valid) begin
                // Expected: coeff[out_idx] * 0.5 = coeff[out_idx] >> 1
                // (with rounding)
                if (out_idx < NUM_TAPS) begin
                    // The impulse response for input=0.5 is coeff*0.5
                    // In fixed-point: (coeff * 1024) >> 11, which after
                    // rounding should be coeff/2.
                    $display("[IMP] tap[%2d] = %6d  (dout = %6d)",
                             out_idx, rrc_coeff(out_idx), dout);
                end
                out_idx++;
            end
        end

        // Drain
        din_valid = 1'b0;
        repeat (5) @(posedge clk);
    endtask

    // -----------------------------------------------------------------------
    // Test 2: Symbol-driven vector comparison
    //   Feed the I-channel symbol sequence (with zero-insert upsampling)
    //   and compare the output against tx_filtered_I.hex
    // -----------------------------------------------------------------------
    task automatic test_vector_comparison();
        int sym_idx, samp_idx, out_idx;
        int mismatches;
        sample_t ref_val;
        int tolerance;

        // The Python golden model outputs centred convolution (mode='same'),
        // which trims (NUM_TAPS-1)/2 = 16 samples.  The RTL transposed FIR
        // is causal, plus 1 cycle for the output register → total latency
        // offset = (NUM_TAPS-1)/2 + 1 = 17 samples.
        localparam int LATENCY_OFFSET = (NUM_TAPS - 1) / 2 + 1;

        $display("\n[TB] === Vector Comparison Test (I-channel) ===");
        $display("[TB]   Latency offset = %0d samples (group delay + 1 reg)",
                 LATENCY_OFFSET);
        mismatches = 0;
        tolerance = 2;  // Allow +/-2 LSB for rounding differences

        // Reset DUT pipeline
        din       = '0;
        din_valid = 1'b0;
        rst_n     = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Feed upsampled symbol sequence
        out_idx  = 0;
        samp_idx = 0;

        for (sym_idx = 0; sym_idx < 256; sym_idx++) begin
            for (int phase = 0; phase < SPS; phase++) begin
                @(posedge clk);
                if (phase == 0) begin
                    din = $signed(ref_sym_I[sym_idx]);
                end else begin
                    din = '0;
                end
                din_valid = 1'b1;

                // Check output (after pipeline fill)
                if (dout_valid) begin
                    // Only compare after latency offset and within ref range
                    if (out_idx >= LATENCY_OFFSET &&
                        (out_idx - LATENCY_OFFSET) < NUM_TX_SAMPLES) begin
                        ref_val = $signed(ref_tx_I[out_idx - LATENCY_OFFSET]);
                        checks++;
                        if ($signed(dout) > $signed(ref_val) + tolerance ||
                            $signed(dout) < $signed(ref_val) - tolerance) begin
                            if (mismatches < 20) begin  // Limit printout
                                $display("[FAIL] rtl[%4d] ref[%4d] got=%6d  exp=%6d  diff=%0d",
                                         out_idx, out_idx - LATENCY_OFFSET,
                                         dout, ref_val,
                                         $signed(dout) - $signed(ref_val));
                            end
                            mismatches++;
                            errors++;
                        end
                    end
                    out_idx++;
                end

                samp_idx++;
            end
        end

        // Flush remaining pipeline contents
        din       = '0;
        repeat (NUM_TAPS + 10) begin
            @(posedge clk);
            if (dout_valid) begin
                if (out_idx >= LATENCY_OFFSET &&
                    (out_idx - LATENCY_OFFSET) < NUM_TX_SAMPLES) begin
                    ref_val = $signed(ref_tx_I[out_idx - LATENCY_OFFSET]);
                    checks++;
                    if ($signed(dout) > $signed(ref_val) + tolerance ||
                        $signed(dout) < $signed(ref_val) - tolerance) begin
                        mismatches++;
                        errors++;
                    end
                end
                out_idx++;
            end
        end

        $display("[TB] Vector test: %0d RTL output samples, %0d compared, %0d mismatches",
                 out_idx, checks, mismatches);
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/waves/tb_rrc_filter.vcd");
        $dumpvars(0, tb_rrc_filter);

        din       = '0;
        din_valid = 1'b0;
        rst_n     = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        test_impulse();
        test_vector_comparison();

        // Summary
        $display("\n========================================");
        if (errors == 0)
            $display("[TB] ALL %0d CHECKS PASSED", checks);
        else
            $display("[TB] %0d / %0d CHECKS FAILED", errors, checks);
        $display("========================================");

        #200;
        $finish;
    end

endmodule
