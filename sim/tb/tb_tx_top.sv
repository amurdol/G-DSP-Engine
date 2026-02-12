// ============================================================================
// G-DSP Engine — Testbench: TX Top (integrated chain verification)
// ============================================================================
// End-to-end verification of the transmit chain:
//   bit_gen (PRBS-23) -> qam16_mapper -> upsample -> rrc_filter
//
// Since the PRBS generator produces a deterministic sequence (from a
// known seed), we can capture the output and compare against the Golden
// Model.  This testbench runs for a configurable number of symbols and
// dumps the I/Q output to a VCD file and to console for inspection.
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -o tb_tx_top \
//       -I ../../sim/vectors \
//       ../../rtl/packages/gdsp_pkg.sv \
//       ../../rtl/common/bit_gen.sv \
//       ../../rtl/modem/qam16_mapper.sv \
//       ../../rtl/modem/rrc_filter.sv \
//       ../../rtl/modem/tx_top.sv \
//       tb_tx_top.sv
//   vvp tb_tx_top
// ============================================================================

`timescale 1ns / 1ps

module tb_tx_top;
    import gdsp_pkg::*;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam int NUM_SYMBOLS   = 64;
    localparam int NUM_SAMPLES   = NUM_SYMBOLS * SPS;
    localparam int PIPELINE_FILL = NUM_TAPS + 10;  // Wait for pipeline

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk   = 0;
    logic rst_n = 0;
    always #18.519 clk = ~clk;  // ~27 MHz

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    logic    en;
    sample_t tx_I, tx_Q;
    logic    tx_valid;
    logic    sym_tick;
    sample_t map_I, map_Q;
    logic    map_valid;

    tx_top u_dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .tx_I      (tx_I),
        .tx_Q      (tx_Q),
        .tx_valid  (tx_valid),
        .sym_tick  (sym_tick),
        .map_I     (map_I),
        .map_Q     (map_Q),
        .map_valid (map_valid)
    );

    // -----------------------------------------------------------------------
    // Monitoring
    // -----------------------------------------------------------------------
    int sample_count = 0;
    int sym_count    = 0;

    always_ff @(posedge clk) begin
        if (tx_valid) begin
            sample_count <= sample_count + 1;
            if (sample_count < 80) begin  // Print first 80 samples
                $display("[TX] sample[%4d] I=%6d  Q=%6d  (sym_tick=%b)",
                         sample_count, tx_I, tx_Q, sym_tick);
            end
        end
        if (sym_tick)
            sym_count <= sym_count + 1;
    end

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/waves/tb_tx_top.vcd");
        $dumpvars(0, tb_tx_top);

        en    = 1'b0;
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (3)  @(posedge clk);

        // Enable the TX chain
        en = 1'b1;

        // Run for enough clocks to produce all symbols + pipeline drain
        repeat (NUM_SAMPLES + PIPELINE_FILL + 50) @(posedge clk);

        en = 1'b0;

        $display("\n========================================");
        $display("[TB] TX Top — Simulation Complete");
        $display("  Symbols generated : %0d", sym_count);
        $display("  Samples output    : %0d", sample_count);
        $display("========================================");

        #200;
        $finish;
    end

endmodule
