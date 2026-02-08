// ============================================================================
// G-DSP Engine — PRBS-23 Bit Generator
// ============================================================================
// Implements a 23-bit Linear Feedback Shift Register (LFSR) following
// ITU-T O.151 (x^23 + x^18 + 1) to produce a continuous pseudo-random
// bit stream.
//
// Operation:
//   - On every clock with (en=1), the LFSR advances 4 positions to
//     produce BITS_PER_SYM bits in parallel (for the QAM mapper).
//   - Output valid is asserted one cycle after enable.
//   - Reset loads a non-zero seed (all-zero is a lock-up state).
// ============================================================================

module bit_gen
    import gdsp_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    en,         // Enable advance
    output logic [BITS_PER_SYM-1:0] bits_out,  // 4-bit parallel output
    output logic                    valid       // Output valid strobe
);

    // -----------------------------------------------------------------------
    // LFSR register — 23 bits, seed must be non-zero
    // Seed comes from gdsp_pkg::LFSR_SEED
    // -----------------------------------------------------------------------
    logic [LFSR_WIDTH-1:0] lfsr_r;
    logic [BITS_PER_SYM-1:0] bits_r;
    logic valid_r;

    // -----------------------------------------------------------------------
    // Advance LFSR by 1 step
    //   Feedback: new_bit = lfsr[22] ^ lfsr[17]   (taps 23 and 18, 0-indexed)
    // -----------------------------------------------------------------------
    function automatic [LFSR_WIDTH-1:0] lfsr_step(
        input [LFSR_WIDTH-1:0] state
    );
        logic fb;
        fb = state[LFSR_TAP_A-1] ^ state[LFSR_TAP_B-1];
        lfsr_step = {state[LFSR_WIDTH-2:0], fb};
    endfunction

    // 4-step unrolled advance (manually unrolled for iverilog compatibility)
    wire [LFSR_WIDTH-1:0] lfsr_s1, lfsr_s2, lfsr_s3, lfsr_s4;
    assign lfsr_s1 = lfsr_step(lfsr_r);
    assign lfsr_s2 = lfsr_step(lfsr_s1);
    assign lfsr_s3 = lfsr_step(lfsr_s2);
    assign lfsr_s4 = lfsr_step(lfsr_s3);

    // MSB of each intermediate state → output bits
    // bit[3] = MSB of lfsr_r (before first step)
    // bit[2] = MSB of lfsr_s1
    // bit[1] = MSB of lfsr_s2
    // bit[0] = MSB of lfsr_s3
    wire [BITS_PER_SYM-1:0] lfsr_msb = {lfsr_r[LFSR_WIDTH-1],
                                          lfsr_s1[LFSR_WIDTH-1],
                                          lfsr_s2[LFSR_WIDTH-1],
                                          lfsr_s3[LFSR_WIDTH-1]};

    // -----------------------------------------------------------------------
    // Sequential logic
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr_r  <= LFSR_SEED;
            bits_r  <= '0;
            valid_r <= 1'b0;
        end else begin
            valid_r <= 1'b0;
            if (en) begin
                lfsr_r  <= lfsr_s4;
                bits_r  <= lfsr_msb;
                valid_r <= 1'b1;
            end
        end
    end

    assign bits_out = bits_r;
    assign valid    = valid_r;

endmodule : bit_gen
