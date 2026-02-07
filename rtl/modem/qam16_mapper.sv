// ============================================================================
// G-DSP Engine — 16-QAM Gray-Coded Mapper
// ============================================================================
// Maps a 4-bit symbol to normalised I/Q constellation values in Q1.11
// fixed-point format.
//
// Gray coding (per axis):
//   2'b00 -> -3    2'b01 -> -1    2'b11 -> +1    2'b10 -> +3
//
// Constellation mapping:
//   bits[3:2] -> I-axis (in-phase)
//   bits[1:0] -> Q-axis (quadrature)
//
// All outputs are normalised by 1/sqrt(10) to give unit average power.
// The LUT values match the Python Golden Model exactly.
//
// Latency: 1 clock cycle (registered output)
// ============================================================================

module qam16_mapper
    import gdsp_pkg::*;
(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic [BITS_PER_SYM-1:0] sym_in,    // 4-bit symbol {I1,I0,Q1,Q0}
    input  logic                    sym_valid,  // Input valid strobe
    output sample_t                 I_out,      // In-phase   (Q1.11)
    output sample_t                 Q_out,      // Quadrature (Q1.11)
    output logic                    iq_valid    // Output valid strobe
);

    // -----------------------------------------------------------------------
    // Per-axis Gray LUT: 2 bits -> signed 12-bit Q1.11 level
    //   Purely combinational lookup using constants from gdsp_pkg.
    // -----------------------------------------------------------------------
    function automatic sample_t gray_lut(input logic [1:0] bits);
        case (bits)
            2'b00:   gray_lut = QAM_NEG3;   // -3/sqrt(10) = -1943
            2'b01:   gray_lut = QAM_NEG1;   // -1/sqrt(10) =  -648
            2'b11:   gray_lut = QAM_POS1;   // +1/sqrt(10) =  +648
            2'b10:   gray_lut = QAM_POS3;   // +3/sqrt(10) = +1943
            default: gray_lut = '0;
        endcase
    endfunction

    // -----------------------------------------------------------------------
    // Registered output stage
    // -----------------------------------------------------------------------
    sample_t I_r, Q_r;
    logic    valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            I_r     <= '0;
            Q_r     <= '0;
            valid_r <= 1'b0;
        end else begin
            valid_r <= 1'b0;
            if (sym_valid) begin
                I_r     <= gray_lut(sym_in[3:2]);
                Q_r     <= gray_lut(sym_in[1:0]);
                valid_r <= 1'b1;
            end
        end
    end

    assign I_out    = I_r;
    assign Q_out    = Q_r;
    assign iq_valid = valid_r;

endmodule : qam16_mapper
