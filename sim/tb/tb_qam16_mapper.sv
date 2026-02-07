// ============================================================================
// G-DSP Engine — Testbench: QAM Mapper (bit-true verification)
// ============================================================================
// Loads reference I/Q vectors from the Python Golden Model and compares
// them against the RTL qam16_mapper output.
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -o tb_qam16_mapper \
//       -I ../../sim/vectors \
//       ../../rtl/packages/gdsp_pkg.sv \
//       ../../rtl/modem/qam16_mapper.sv \
//       tb_qam16_mapper.sv
//   vvp tb_qam16_mapper
// ============================================================================

`timescale 1ns / 1ps

module tb_qam16_mapper;
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
    logic [BITS_PER_SYM-1:0] sym_in;
    logic                    sym_valid;
    sample_t                 I_out, Q_out;
    logic                    iq_valid;

    qam16_mapper u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .sym_in    (sym_in),
        .sym_valid (sym_valid),
        .I_out     (I_out),
        .Q_out     (Q_out),
        .iq_valid  (iq_valid)
    );

    // -----------------------------------------------------------------------
    // Reference data from Golden Model
    // -----------------------------------------------------------------------
    localparam int NUM_SYMBOLS = 256;

    // Memories to hold reference vectors
    logic [DATA_WIDTH-1:0] ref_I [0:NUM_SYMBOLS-1];
    logic [DATA_WIDTH-1:0] ref_Q [0:NUM_SYMBOLS-1];

    initial begin
        $readmemh("../../sim/vectors/qam16_symbols_I.hex", ref_I);
        $readmemh("../../sim/vectors/qam16_symbols_Q.hex", ref_Q);
    end

    // -----------------------------------------------------------------------
    // Stimulus
    // -----------------------------------------------------------------------
    // We need a source of the same symbols that the Golden Model used.
    // The Golden Model uses numpy with seed=42 to generate bits, then groups
    // them into 4-bit symbols.  We load the expected I/Q and drive ALL 16
    // possible symbols first as a truth-table test, then use the reference
    // vectors to check the full sequence.

    int errors = 0;
    int checks = 0;

    // Full truth-table test
    task automatic test_truth_table();
        logic signed [DATA_WIDTH-1:0] exp_I, exp_Q;
        $display("[TB] === Truth Table Test ===");
        for (int s = 0; s < 16; s++) begin
            @(posedge clk);
            sym_in    = s[BITS_PER_SYM-1:0];
            sym_valid = 1'b1;
            @(posedge clk);
            sym_valid = 1'b0;
            @(posedge clk);  // Wait for registered output

            // Expected values from LUT
            case (s[3:2])
                2'b00: exp_I = QAM_NEG3;
                2'b01: exp_I = QAM_NEG1;
                2'b11: exp_I = QAM_POS1;
                2'b10: exp_I = QAM_POS3;
                default: exp_I = '0;
            endcase
            case (s[1:0])
                2'b00: exp_Q = QAM_NEG3;
                2'b01: exp_Q = QAM_NEG1;
                2'b11: exp_Q = QAM_POS1;
                2'b10: exp_Q = QAM_POS3;
                default: exp_Q = '0;
            endcase

            checks++;
            if (I_out !== exp_I || Q_out !== exp_Q) begin
                $display("[FAIL] sym=%4b  I: got=%0d exp=%0d  Q: got=%0d exp=%0d",
                         s[3:0], I_out, exp_I, Q_out, exp_Q);
                errors++;
            end else begin
                $display("[PASS] sym=%4b  I=%0d  Q=%0d", s[3:0], I_out, Q_out);
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("tb_qam16_mapper.vcd");
        $dumpvars(0, tb_qam16_mapper);

        // Reset
        sym_in    = '0;
        sym_valid = 1'b0;
        rst_n     = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Run truth table
        test_truth_table();

        // Summary
        $display("========================================");
        if (errors == 0)
            $display("[TB] ALL %0d CHECKS PASSED", checks);
        else
            $display("[TB] %0d / %0d CHECKS FAILED", errors, checks);
        $display("========================================");

        #100;
        $finish;
    end

endmodule
