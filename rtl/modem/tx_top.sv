// ============================================================================
// G-DSP Engine — TX Subsystem Top-Level
// ============================================================================
// Integrates the complete transmit chain:
//
//   bit_gen (PRBS-23) → qam16_mapper (Gray) → [upsample ×4] → rrc_filter
//
// Data flow timing:
//   The bit_gen produces 4 bits every SPS (=4) clocks.  The QAM mapper
//   converts them to I/Q symbols.  A zero-insert upsampler then feeds
//   the symbol once and zeros for the remaining 3 clocks into the RRC
//   filter, which runs at the full sample rate (1 sample/clock).
//
// Handshaking:
//   - sym_tick:   one-cycle pulse every SPS clocks (symbol rate strobe)
//   - sample_en:  asserted every clock (sample rate = clk frequency)
//
// Latency:
//   bit_gen(1) + mapper(1) + upsample(0) + rrc(1) = 3 clocks + filter
//   group delay of (NUM_TAPS-1)/2 = 16 samples.
// ============================================================================

module tx_top
    import gdsp_pkg::*;
(
    input  logic     clk,
    input  logic     rst_n,
    input  logic     en,            // Global enable
    output sample_t  tx_I,          // Filtered I output (Q1.11)
    output sample_t  tx_Q,          // Filtered Q output (Q1.11)
    output logic     tx_valid,      // Output valid strobe
    output logic     sym_tick       // Symbol-rate strobe (debug/sync)
);

    // -----------------------------------------------------------------------
    // Symbol-rate strobe generator: 1 pulse every SPS clocks
    // -----------------------------------------------------------------------
    logic [$clog2(SPS)-1:0] sps_cnt;
    logic sym_strobe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sps_cnt    <= '0;
            sym_strobe <= 1'b0;
        end else if (en) begin
            if (sps_cnt == SPS - 1) begin
                sps_cnt    <= '0;
                sym_strobe <= 1'b1;
            end else begin
                sps_cnt    <= sps_cnt + 1'b1;
                sym_strobe <= 1'b0;
            end
        end else begin
            sps_cnt    <= '0;
            sym_strobe <= 1'b0;
        end
    end

    assign sym_tick = sym_strobe;

    // -----------------------------------------------------------------------
    // Bit Generator (PRBS-23)
    // -----------------------------------------------------------------------
    logic [BITS_PER_SYM-1:0] bits;
    logic bits_valid;

    bit_gen u_bit_gen (
        .clk      (clk),
        .rst_n    (rst_n),
        .en       (sym_strobe),
        .bits_out (bits),
        .valid    (bits_valid)
    );

    // -----------------------------------------------------------------------
    // 16-QAM Mapper (Gray coded)
    // -----------------------------------------------------------------------
    sample_t sym_I, sym_Q;
    logic    sym_valid;

    qam16_mapper u_mapper (
        .clk       (clk),
        .rst_n     (rst_n),
        .sym_in    (bits),
        .sym_valid (bits_valid),
        .I_out     (sym_I),
        .Q_out     (sym_Q),
        .iq_valid  (sym_valid)
    );

    // -----------------------------------------------------------------------
    // Zero-Insert Upsampler (×SPS)
    //
    //   When sym_valid is asserted, output the symbol value.
    //   For the next SPS-1 clocks, output zero.
    //   This creates the impulse train that the RRC filter shapes.
    //
    //   Timing: sym_valid arrives 2 clocks after sym_strobe (bit_gen + mapper
    //   pipeline).  We hold the symbol and gate with a local SPS counter
    //   that starts on sym_valid.
    // -----------------------------------------------------------------------
    sample_t up_I, up_Q;
    logic    up_valid;

    // Upsampler counter
    logic [$clog2(SPS)-1:0] up_cnt;
    logic up_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            up_I      <= '0;
            up_Q      <= '0;
            up_valid  <= 1'b0;
            up_cnt    <= '0;
            up_active <= 1'b0;
        end else begin
            if (sym_valid) begin
                // New symbol arrives — output it and start counting
                up_I      <= sym_I;
                up_Q      <= sym_Q;
                up_valid  <= 1'b1;
                up_cnt    <= 1;          // count remaining zeros
                up_active <= 1'b1;
            end else if (up_active && en) begin
                // Insert zeros for the remaining SPS-1 samples
                up_I     <= '0;
                up_Q     <= '0;
                up_valid <= 1'b1;
                if (up_cnt == SPS - 1) begin
                    up_cnt    <= '0;
                    up_active <= 1'b0;
                end else begin
                    up_cnt <= up_cnt + 1'b1;
                end
            end else begin
                up_valid <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // RRC Pulse-Shaping Filters (I and Q channels)
    // -----------------------------------------------------------------------
    sample_t filt_I, filt_Q;
    logic    filt_I_valid, filt_Q_valid;

    rrc_filter u_rrc_I (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (up_I),
        .din_valid  (up_valid),
        .dout       (filt_I),
        .dout_valid (filt_I_valid)
    );

    rrc_filter u_rrc_Q (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (up_Q),
        .din_valid  (up_valid),
        .dout       (filt_Q),
        .dout_valid (filt_Q_valid)
    );

    // -----------------------------------------------------------------------
    // Output assignments
    // -----------------------------------------------------------------------
    assign tx_I     = filt_I;
    assign tx_Q     = filt_Q;
    assign tx_valid = filt_I_valid;  // I and Q are always synchronised

endmodule : tx_top
