// ============================================================================
// G-DSP Engine — Gardner Timing Error Detector (TED)
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Implements a non-data-aided Gardner timing recovery loop for symbol
// synchronisation at SPS=4 samples/symbol.
//
// Architecture:
//   1. NCO-based timing phase accumulator (16-bit)
//   2. Linear interpolator for sub-sample prompt estimation
//   3. Gardner error detector: e = (prev − curr) · mid  (I + Q)
//   4. PI loop filter (shift-based gains, no extra multipliers)
//
// Gardner Algorithm (non data-aided):
//   Error:  e[n] = { I[n-1] − I[n] } · I_mid  +  { Q[n-1] − Q[n] } · Q_mid
//
//   Where:
//     I[n], Q[n]       = current prompt (optimally timed sample)
//     I[n-1], Q[n-1]   = previous prompt
//     I_mid, Q_mid     = sample at the midpoint between prompts
//
// NCO Operation:
//   Phase accumulator increments by NCO_STEP ± correction each valid
//   input sample.  Overflow → symbol strobe.  Lower bits → µ for
//   interpolation.
//
// Linear Interpolator:
//   y = x_curr + µ · (x_prev − x_curr),  µ = overshoot / NCO_STEP.
//   For SPS=4, NCO_STEP = 2^14, so µ is the lower 14 bits of nco_sum.
//
// DSP Budget: 4 multipliers (2 interpolation + 2 error), all at or
//   below symbol rate.
//
// Latency: 1 clock from NCO wrap to sym_strobe.
// ============================================================================

module gardner_ted
    import gdsp_pkg::*;
(
    input  logic    clk,
    input  logic    rst_n,

    // --- Matched-filter output (sample rate) ---
    input  sample_t din_I,          // I channel (Q1.11)
    input  sample_t din_Q,          // Q channel (Q1.11)
    input  logic    din_valid,      // Sample-rate valid strobe

    // --- Symbol-rate output (optimally timed) ---
    output sample_t sym_I,          // I prompt at optimal timing (Q1.11)
    output sample_t sym_Q,          // Q prompt at optimal timing (Q1.11)
    output logic    sym_strobe      // One pulse per recovered symbol
);

    // ====================================================================
    // NCO Parameters
    // ====================================================================
    localparam int NCO_W    = 16;
    localparam int NCO_STEP = (1 << NCO_W) / SPS;   // 16384 for SPS=4
    localparam int MU_W     = NCO_W - $clog2(SPS);   // 14 bits

    // Loop filter gains (implemented as right-shifts — multiplier-free).
    //   Kp = 2^{-KP_SHIFT},  Ki = 2^{-KI_SHIFT}.
    //   Moderate bandwidth: fast pull-in, low self-noise once locked.
    localparam int KP_SHIFT = 8;    // Kp ≈ 1/256 (conservative)
    localparam int KI_SHIFT = 14;   // Ki ≈ 1/16384 (was 16, caused warning)

    // Dead zone: ignore timing errors below this threshold.
    // Prevents quantization-noise-induced integrator drift.
    localparam int TED_DEAD_ZONE = 30;

    // ====================================================================
    // Previous-sample register (for linear interpolation)
    // ====================================================================
    sample_t prev_I, prev_Q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_I <= '0;
            prev_Q <= '0;
        end else if (din_valid) begin
            prev_I <= din_I;
            prev_Q <= din_Q;
        end
    end

    // ====================================================================
    // NCO — Timing Phase Accumulator
    //
    //   phase += step_clamped   every din_valid.
    //   Overflow (bit NCO_W) → symbol boundary detected.
    // ====================================================================
    logic [NCO_W-1:0]        nco_phase;
    logic [NCO_W:0]          nco_sum;
    logic                    nco_wrap;
    logic signed [NCO_W-1:0] nco_adj;

    // Signed step = nominal + correction, clamped to [1, 2·NCO_STEP]
    wire signed [NCO_W:0] step_signed =
        $signed({1'b0, NCO_W'(NCO_STEP)}) + $signed(nco_adj);
    wire [NCO_W-1:0] step_clamped =
        (step_signed <= 0) ? NCO_W'(1) :
        (step_signed > $signed({1'b0, NCO_W'(2*NCO_STEP)}))
            ? NCO_W'(2*NCO_STEP) : NCO_W'(step_signed);

    assign nco_sum  = {1'b0, nco_phase} + {1'b0, step_clamped};
    assign nco_wrap = nco_sum[NCO_W] & din_valid;

    // Initialise the NCO so that the FIRST strobe fires at sample 0
    // (phase 0).  In a synchronous system the cascade group delay is
    // an exact multiple of SPS, so the optimal sampling phase is 0.
    // Starting at (SPS−1)·NCO_STEP causes overflow after exactly 1 sample.
    localparam [NCO_W-1:0] NCO_INIT = NCO_W'((SPS - 1) * NCO_STEP);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            nco_phase <= NCO_INIT;
        else if (din_valid)
            nco_phase <= nco_sum[NCO_W-1:0];
    end

    // ====================================================================
    // Linear Interpolator
    //
    //   µ = overshoot [MU_W-1:0].  µ = 0 → ideal at din ; µ = max → prev.
    //   y = din + (µ · (prev − din)) >> MU_W
    //
    //   2 multipliers: 15-bit(µ) × 13-bit(diff) = 28-bit
    // ====================================================================
    wire [MU_W-1:0] mu = nco_sum[MU_W-1:0];

    wire signed [DATA_WIDTH:0] idiff = {prev_I[DATA_WIDTH-1], prev_I}
                                     - {din_I[DATA_WIDTH-1], din_I};
    wire signed [DATA_WIDTH:0] qdiff = {prev_Q[DATA_WIDTH-1], prev_Q}
                                     - {din_Q[DATA_WIDTH-1], din_Q};

    wire signed [MU_W:0] mu_s = $signed({1'b0, mu});

    wire signed [MU_W+DATA_WIDTH:0] iprod = idiff * mu_s;
    wire signed [MU_W+DATA_WIDTH:0] qprod = qdiff * mu_s;

    wire sample_t interp_I = din_I + sample_t'(iprod >>> MU_W);
    wire sample_t interp_Q = din_Q + sample_t'(qprod >>> MU_W);

    // ====================================================================
    // Prompt / Mid-Sample / Previous-Symbol Storage
    //
    //   prompt  — interpolated at NCO strobe.
    //   mid     — raw sample captured SPS/2 valid clocks after the
    //             *previous* strobe (mid-point between two prompts).
    //   prev_sym — previous prompt, latched after error computation.
    // ====================================================================
    sample_t prompt_I_r, prompt_Q_r;
    sample_t prev_sym_I,  prev_sym_Q;
    sample_t mid_I_r,     mid_Q_r;
    logic [$clog2(SPS):0] mid_cnt;
    logic                 strobe_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prompt_I_r <= '0;   prompt_Q_r <= '0;
            prev_sym_I <= '0;   prev_sym_Q <= '0;
            mid_I_r    <= '0;   mid_Q_r    <= '0;
            mid_cnt    <= '0;
            strobe_r   <= 1'b0;
        end else begin
            strobe_r <= 1'b0;                            // default

            if (nco_wrap) begin
                // NCO overflow → latch prompt, emit strobe
                prompt_I_r <= interp_I;
                prompt_Q_r <= interp_Q;
                strobe_r   <= 1'b1;
                mid_cnt    <= 1;
            end else if (din_valid && mid_cnt != 0) begin
                // Count valid samples after strobe to capture mid
                if (mid_cnt == ($clog2(SPS)+1)'(SPS / 2)) begin
                    mid_I_r <= din_I;
                    mid_Q_r <= din_Q;
                    mid_cnt <= '0;
                end else begin
                    mid_cnt <= mid_cnt + 1'b1;
                end
            end

            // One cycle after strobe: archive prompt → prev_sym
            if (strobe_r) begin
                prev_sym_I <= prompt_I_r;
                prev_sym_Q <= prompt_Q_r;
            end
        end
    end

    // ====================================================================
    // Gardner Error Computation (combinational, sampled at strobe_r)
    //
    //   e = (prev_sym − prompt) · mid      (I and Q summed)
    //   Product: 13 × 12 = 25 bits.  Upper DATA_WIDTH bits → loop filter.
    // ====================================================================
    wire signed [DATA_WIDTH:0] dsym_I = {prev_sym_I[DATA_WIDTH-1], prev_sym_I}
                                      - {prompt_I_r[DATA_WIDTH-1], prompt_I_r};
    wire signed [DATA_WIDTH:0] dsym_Q = {prev_sym_Q[DATA_WIDTH-1], prev_sym_Q}
                                      - {prompt_Q_r[DATA_WIDTH-1], prompt_Q_r};

    localparam int ERR_PROD_W = (DATA_WIDTH + 1) + DATA_WIDTH;  // 25

    wire signed [ERR_PROD_W-1:0] err_I_prod = dsym_I * mid_I_r;
    wire signed [ERR_PROD_W-1:0] err_Q_prod = dsym_Q * mid_Q_r;

    wire signed [ERR_PROD_W:0] ted_err_full = {err_I_prod[ERR_PROD_W-1], err_I_prod}
                                            + {err_Q_prod[ERR_PROD_W-1], err_Q_prod};

    // Take upper DATA_WIDTH bits as normalised error
    wire signed [DATA_WIDTH-1:0] ted_error =
        ted_err_full[ERR_PROD_W -: DATA_WIDTH];

    // ====================================================================
    // PI Loop Filter
    //
    //   proportional = −(e >> KP_SHIFT)
    //   integrator  += −(e >> KI_SHIFT)          (anti-windup clamped)
    //   nco_adj      = proportional + integrator
    //
    //   Holdoff: the loop filter is frozen during the first HOLDOFF_SYMS
    //   symbols to avoid accumulating integrator bias from the matched-
    //   filter fill-up transient (where the error is large and meaningless).
    // ====================================================================
    localparam int HOLDOFF_SYMS = 16;    // Freeze loop for first 16 symbols
    localparam signed [NCO_W-1:0] INT_BOUND = (1 <<< (NCO_W - 2)) - 1;

    logic signed [NCO_W-1:0] integrator;
    logic [7:0]              lf_holdoff;    // Symbol counter
    wire  signed [NCO_W-1:0] err_ext  = NCO_W'($signed(ted_error));

    // Truncate-toward-zero then negate (loop polarity).
    // Avoids asymmetric rounding bias from arithmetic right shift.
    wire  signed [NCO_W-1:0] prop_term = (err_ext >= 0) ? -(err_ext >>> KP_SHIFT)
                                                         :  ((-err_ext) >>> KP_SHIFT);
    wire  signed [NCO_W-1:0] int_delta = (err_ext >= 0) ? -(err_ext >>> KI_SHIFT)
                                                         :  ((-err_ext) >>> KI_SHIFT);
    wire  signed [NCO_W-1:0] int_next  = integrator + int_delta;

    wire lf_active = (lf_holdoff >= HOLDOFF_SYMS[7:0]);

    // Absolute value of error for dead-zone check
    wire [DATA_WIDTH-1:0] ted_err_abs = (ted_error < 0)
        ? DATA_WIDTH'(-ted_error) : DATA_WIDTH'(ted_error);
    wire ted_err_significant = (ted_err_abs > TED_DEAD_ZONE[DATA_WIDTH-1:0]);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integrator <= '0;
            nco_adj    <= '0;
            lf_holdoff <= '0;
        end else if (strobe_r) begin
            // Holdoff counter (saturates)
            if (lf_holdoff < 8'd255)
                lf_holdoff <= lf_holdoff + 1'b1;

            if (lf_active) begin
                // Integrator update: only when error is significant (dead zone)
                // Prevents noise-driven drift when timing is already locked.
                if (ted_err_significant) begin
                    // Anti-windup clamp
                    if (int_next > INT_BOUND)
                        integrator <= INT_BOUND;
                    else if (int_next < -INT_BOUND)
                        integrator <= -INT_BOUND;
                    else
                        integrator <= int_next;
                end

                // NCO adjustment: ALWAYS update (proportional + integrator)
                // This ensures recovery when noise disappears.
                nco_adj <= prop_term + integrator;
            end
        end
    end

    // ====================================================================
    // Output
    // ====================================================================
    assign sym_I      = prompt_I_r;
    assign sym_Q      = prompt_Q_r;
    assign sym_strobe = strobe_r;

endmodule : gardner_ted
