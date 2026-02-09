// ============================================================================
// G-DSP Engine — AWGN Generator (Central Limit Theorem)
// ============================================================================
// Generates approximately Gaussian-distributed noise samples using the
// Central Limit Theorem (CLT).
//
// ---- Theory ----
//
//   The CLT states that the sum of N independent, identically distributed
//   (i.i.d.) uniform random variables converges to a Gaussian distribution
//   as N grows.  For N = 8 uniform sources, the resulting distribution
//   has excess kurtosis of only 3/8 ≈ 0.375 (vs. 0 for a true Gaussian),
//   which is acceptable for BER testing at Eb/No ≥ 6 dB.
//
//   Alternative approaches considered but rejected:
//
//   * Box-Muller: requires ln() and sqrt() — either CORDIC or large LUTs,
//     consuming 2–4 BSRAM blocks and > 1,000 LUTs on GW1NR-9.
//
//   * Ziggurat: requires a comparison + rejection loop with variable
//     latency, complicating the deterministic pipeline.
//
//   The CLT approach is entirely combinational/pipelined, uses no BSRAM,
//   and produces one noise sample per clock cycle with fixed latency.
//
// ---- Architecture ----
//
//   1. 8 independent LFSRs of different lengths (15–25 bits) with
//      distinct primitive polynomials to eliminate cross-correlation.
//      Each LFSR outputs its top 12 bits as a uniform sample.
//
//   2. The 8 unsigned 12-bit samples are summed (result: 15 bits).
//
//   3. The mean of the sum is subtracted to center the distribution at
//      zero: centred = sum − 8 × 2048 = sum − 16384.
//      This yields a signed 16-bit value.
//
//   4. The centred value is normalised (right-shifted) and then scaled
//      by noise_magnitude to control the output variance.
//
//   5. The result is truncated to Q1.11 (12-bit signed).
//
// ---- Noise Magnitude to SNR Mapping ----
//
//   Each uniform LFSR output has variance σ²_u = (2^12)² / 12.
//   Sum of 8 such variables: σ²_sum = 8 × (2^12)² / 12.
//   After centring and normalisation (÷ 2^(3+FRAC_BITS)):
//     σ²_norm ≈ 1/12.
//   After scaling by noise_magnitude (M, 0..255):
//     σ²_noise = (M/256)² × σ²_norm
//     σ_noise ≈ M / (256 × √12)  ≈ M / 886.8
//
//   For 16-QAM with unit-power constellation (signal power Ps = 1):
//     SNR = Ps / (2 × σ²_noise)  [factor 2 for I+Q channels]
//     SNR_dB ≈ 10 × log10(1 / (2 × (M/886.8)²))
//            = 10 × log10(886.8² / (2 × M²))
//            ≈ 58.95 − 20 × log10(M)
//
//   Examples:
//     M =   8  → SNR ≈ 40.9 dB (nearly clean)
//     M =  32  → SNR ≈ 28.8 dB 
//     M =  64  → SNR ≈ 22.8 dB
//     M = 128  → SNR ≈ 16.8 dB 
//     M = 255  → SNR ≈ 10.8 dB (heavy noise)
//
// Latency: 3 clock cycles (pipeline: LFSR → sum → scale+truncate)
// ============================================================================

module awgn_generator
    import gdsp_pkg::*;
#(
    parameter int INSTANCE_ID = 0  // Unique per instance (0=I, 1=Q)
                                   // XOR'd into seeds to guarantee
                                   // statistical independence.
)
(
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          en,              // Sample enable
    input  logic [NOISE_MAG_WIDTH-1:0]    noise_magnitude, // 0..255
    output sample_t                       noise_out,       // Gaussian noise Q1.11
    output logic                          noise_valid      // Output valid
);

    // -----------------------------------------------------------------------
    // Stage 1: 8 independent LFSRs with distinct primitive polynomials
    // -----------------------------------------------------------------------
    // Each LFSR has a different width (15..25 bits) and polynomial.
    // We extract the top DATA_WIDTH (12) bits as unsigned uniform output.
    //
    // Seeds are staggered to prevent identical start-up patterns.
    // -----------------------------------------------------------------------

    logic [31:0] lfsr_r [0:NUM_LFSR_NOISE-1];  // Max width = 31 bits
    logic [DATA_WIDTH-1:0] uniform [0:NUM_LFSR_NOISE-1]; // 12-bit unsigned

    // LFSR step function — parameterised per instance
    function automatic [31:0] lfsr_advance(
        input [31:0] state,
        input int    width,
        input int    tap_a,
        input int    tap_b
    );
        logic fb;
        fb = state[tap_a-1] ^ state[tap_b-1];
        lfsr_advance = {state[30:0], fb} & ((32'b1 << width) - 1);
    endfunction

    generate
        for (genvar g = 0; g < NUM_LFSR_NOISE; g++) begin : gen_lfsr
            // Unique non-zero seed per LFSR.
            // The INSTANCE_ID ensures that two awgn_generator instantiations
            // (I-channel vs Q-channel) receive completely different seed sets,
            // preventing correlated noise between I and Q branches.
            //
            // Construction:
            //   base  = 0xDEAD_BEE0 + g * 0x1357_9BDF   (spread by index)
            //   mix   = base ^ (0xA5A5_A5A5 >> g)        (bit decorrelation)
            //   inst  = mix ^ (INSTANCE_ID * 0x5A5A_DEAD) (I/Q separation)
            //   seed  = inst | 1                          (guarantee non-zero)
            //   final = seed & ((1 << width) - 1)         (mask to LFSR width)
            // Per-LFSR polynomial parameters (function lookup for iverilog compat)
            localparam int W  = noise_lfsr_width(g);
            localparam int TA = noise_lfsr_tap_a(g);
            localparam int TB = noise_lfsr_tap_b(g);

            localparam [31:0] SEED_BASE = (32'hDEAD_BEE0 + g[4:0] * 32'h1357_9BDF)
                                          ^ (32'hA5A5_A5A5 >> g[4:0]);
            localparam [31:0] SEED_INST = SEED_BASE
                                          ^ (INSTANCE_ID[3:0] * 32'h5A5A_DEAD);
            localparam [31:0] SEED_VAL  = SEED_INST | 32'h1;

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    lfsr_r[g] <= SEED_VAL & ((32'b1 << W) - 1)
                                 | 32'h1;
                end else if (en) begin
                    lfsr_r[g] <= lfsr_advance(lfsr_r[g], W, TA, TB);
                end
            end

            // Extract top 12 bits from each LFSR as unsigned uniform sample
            assign uniform[g] = lfsr_r[g][W-1 -: DATA_WIDTH];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Stage 2 (pipeline register): Sum all 16 uniform samples
    //
    //   Sum range: 0 to 16 × 4095 = 65520 → needs 16 bits unsigned.
    //   Mean = 16 × 2047.5 = 32760.
    //   We centre by subtracting 32768 (close to mean, power-of-2 for
    //   free subtraction via bit inversion + 1).
    //
    //   Centred range: −32768 to +32752 → 17-bit signed.
    //   We divide by 16 (shift right 4) to normalise σ, then keep 12 bits.
    // -----------------------------------------------------------------------
    logic [NOISE_SUM_WIDTH-1:0] sum_stage1;  // 16-bit intermediate sums
    logic signed [NOISE_SUM_WIDTH:0] centred; // 17-bit signed (centred)
    logic signed [NOISE_SUM_WIDTH:0] centred_r;
    logic en_d1, en_d2;

    // Combinational adder tree in 3 levels (8→4→2→1)
    logic [NOISE_SUM_WIDTH-1:0] lvl0 [0:3];
    logic [NOISE_SUM_WIDTH-1:0] lvl1 [0:1];

    always_comb begin
        // Level 0: pair-wise add (8 → 4)
        for (int i = 0; i < 4; i++) begin
            lvl0[i] = {3'b0, uniform[2*i]} + {3'b0, uniform[2*i+1]};
        end
        // Level 1: (4 → 2)
        lvl1[0] = lvl0[0] + lvl0[1];
        lvl1[1] = lvl0[2] + lvl0[3];
        // Level 2: (2 → 1)
        sum_stage1 = lvl1[0] + lvl1[1];
    end

    // Centre the sum: subtract mean (16384 = 8 * 2048 = 8 * mid-scale of 12-bit)
    assign centred = $signed({1'b0, sum_stage1}) - $signed(16'sd16384);

    // Pipeline register for sum
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            centred_r <= '0;
            en_d1     <= 1'b0;
        end else begin
            en_d1     <= en;
            centred_r <= centred;
        end
    end

    // -----------------------------------------------------------------------
    // Stage 3 (pipeline register): Scale by noise_magnitude and truncate
    //
    //   Normalised noise = centred_r >>> 3  (divide by 8 → ~unit variance)
    //   This gives a 13-bit signed value with ~1 bit integer range.
    //
    //   Scaled noise = normalised × noise_magnitude / 256
    //   Implemented as: (centred_r × noise_magnitude) >>> (3 + 8) = >>> 11
    //
    //   Product width: 16 + 8 = 24 bits signed.
    //   After >>> 11: keep top 13 bits, truncate to 12 with saturation.
    // -----------------------------------------------------------------------
    logic signed [NOISE_SUM_WIDTH + NOISE_MAG_WIDTH : 0] scaled_product; // 24 bits
    logic signed [DATA_WIDTH-1:0] noise_trunc;
    sample_t noise_r;
    logic    valid_r;

    // Multiply centred noise by magnitude
    assign scaled_product = centred_r * $signed({1'b0, noise_magnitude});

    // Shift right by 11 (÷8 for normalisation × ÷256 for magnitude scaling)
    // and truncate to 12-bit Q1.11
    logic signed [NOISE_SUM_WIDTH + NOISE_MAG_WIDTH : 0] shifted;
    assign shifted = scaled_product >>> 11;

    // Saturation to Q1.11 range [−2048, +2047]
    wire signed [DATA_WIDTH-1:0] shifted_trunc = shifted[DATA_WIDTH-1:0];

    always_comb begin
        if (shifted > 25'sd2047)
            noise_trunc = 12'sd2047;
        else if (shifted < -25'sd2048)
            noise_trunc = -12'sd2048;
        else
            noise_trunc = shifted_trunc;
    end

    // Output register
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            noise_r <= '0;
            valid_r <= 1'b0;
            en_d2   <= 1'b0;
        end else begin
            en_d2   <= en_d1;
            noise_r <= noise_trunc;
            valid_r <= en_d2;
        end
    end

    assign noise_out   = noise_r;
    assign noise_valid = valid_r;

endmodule : awgn_generator
