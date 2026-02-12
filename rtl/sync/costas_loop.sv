// ============================================================================
// G-DSP Engine — Decision-Directed Costas Loop (Carrier Recovery)
// ============================================================================
// Author : G-DSP Team
// Project: TFG — 16-QAM Baseband Processor on Gowin GW1NR-9
// License: MIT
// ============================================================================
//
// Implements a Decision-Directed Phase-Locked Loop (DD-PLL) adapted for
// 16-QAM carrier/phase recovery.
//
// Why not a classic Costas Loop?
//   The standard Costas detector  Q·sgn(I) − I·sgn(Q)  works for BPSK/QPSK
//   but fails for multi-level QAM because the inner-ring symbols produce
//   an ambiguous error gradient.  A decision-directed detector uses the
//   hard-decision slicer output to compute the cross-product phase error,
//   which generalises naturally to any rectangular QAM.
//
// Architecture (2-stage pipeline at symbol rate):
//
//   Stage 1 — Phase Rotator (CONJUGATE to remove channel phase):
//     rot_I = sym_I · cos(θ) + sym_Q · sin(θ)
//     rot_Q = sym_Q · cos(θ) − sym_I · sin(θ)
//     sin/cos from a quarter-wave LUT (65 × 12-bit) with quadrant folding.
//     4 multipliers, but active only at symbol rate (~27/4 ≈ 6.75 MHz).
//
//   Stage 2 — Error + Loop Filter + NCO:
//     Slicer  : map rot_I/Q to nearest 16-QAM constellation point.
//     Error   : e = rot_I · Q_hat − rot_Q · I_hat   (cross-product)
//     Loop filt: Type-2 PI  →  ω (freq est.)  →  θ (NCO phase)
//     Lock det : exponential average of |e|; demod_lock when avg < threshold.
//
// Sin/Cos LUT:
//   Quarter-wave cosine, 65 entries (0..64), Q1.11.
//   Full circle via quadrant folding on the upper 8 bits of the 16-bit
//   NCO phase.  Memory: 65 × 12 = 780 bits (tiny; fits in LUTs or 1 BSRAM).
//
// DSP Budget: 6 multipliers (4 rotator + 2 error), all at symbol rate.
// Latency: 2 clock cycles from sym_strobe to demod_valid.
// ============================================================================

module costas_loop
    import gdsp_pkg::*;
(
    input  logic    clk,
    input  logic    rst_n,

    // --- Symbol-rate input (from Gardner TED) ---
    input  sample_t sym_I,          // I prompt (Q1.11)
    input  sample_t sym_Q,          // Q prompt (Q1.11)
    input  logic    sym_strobe,     // One pulse per symbol

    // --- Demodulated output ---
    output sample_t demod_I,        // De-rotated I (Q1.11)
    output sample_t demod_Q,        // De-rotated Q (Q1.11)
    output logic    demod_valid,    // Output valid (1 per symbol)
    output logic    demod_lock      // Lock indicator (1 = loop converged)
);

    // ====================================================================
    // Parameters
    // ====================================================================
    localparam int NCO_W = 16;          // Phase accumulator width

    // Loop filter gains (shift-based)
    //   Kp controls proportional (instantaneous phase correction).
    //   Ki uses gear shifting: aggressive during acquisition for fast
    //   pull-in (KI_SHIFT_ACQ), then conservative during tracking to
    //   prevent noise-driven drift (KI_SHIFT_TRK).
    //   Gear shifting (dual Kp/Ki) for robust acquisition + tracking:
    //     Acquisition : weak Kp, strong Ki  → integrator dominates,
    //                   converges omega to freq offset without Kp stealing error.
    //     Tracking    : strong Kp, frozen Ki → fast phase fine-tuning,
    //                   omega stays locked at the acquired value.
    //   NOTE: Increased gains for robust acquisition with 5-tap ISI (~20%).
    localparam int KP_SHIFT_ACQ = 5;     // Acquisition Kp ≈ 1/32  (stronger for ISI)
    localparam int KP_SHIFT_TRK = 3;     // Tracking   Kp ≈ 1/8   (strong)
    localparam int KI_SHIFT_ACQ = 4;     // Acquisition Ki ≈ 1/16  (aggressive)
    localparam int KI_SHIFT_TRK = 12;    // Tracking   Ki ≈ 1/4096 (frozen)
    localparam int GEAR_SHIFT_SYM = 300; // Switch after 300 symbols (more time)

    // Dead zone: integrator ignores errors below this threshold.
    //   Prevents quantisation noise from accumulating into omega.
    localparam int DEAD_ZONE = 50;

    // Lock detector
    localparam int LOCK_AVG_SHIFT = 6;  // Averaging time constant ~64 symbols
    localparam int LOCK_THRESHOLD = 150; // Raw |error| threshold (Q format ~12-bit)

    // 16-QAM slicer threshold: midpoint between inner & outer levels
    //   With 5-tap RRC (peak gain ~1.0), levels are original:
    //   ±648, ±1943. Threshold = (648 + 1943) / 2 = 1296
    localparam sample_t SLICER_TH = 12'sd1296;

    // ====================================================================
    // Quarter-Wave Cosine LUT  (65 entries, Q1.11)
    //
    //   cos_quarter_lut(i) = round(cos(π·i/128) · 2047)
    //   i = 0 → cos(0)   = 2047
    //   i =64 → cos(π/2) = 0
    // ====================================================================
    function automatic sample_t cos_quarter_lut(input logic [6:0] idx);
        case (idx)
            7'd 0: cos_quarter_lut = 12'sd2047;
            7'd 1: cos_quarter_lut = 12'sd2046;
            7'd 2: cos_quarter_lut = 12'sd2045;
            7'd 3: cos_quarter_lut = 12'sd2041;
            7'd 4: cos_quarter_lut = 12'sd2037;
            7'd 5: cos_quarter_lut = 12'sd2032;
            7'd 6: cos_quarter_lut = 12'sd2025;
            7'd 7: cos_quarter_lut = 12'sd2017;
            7'd 8: cos_quarter_lut = 12'sd2008;
            7'd 9: cos_quarter_lut = 12'sd1997;
            7'd10: cos_quarter_lut = 12'sd1986;
            7'd11: cos_quarter_lut = 12'sd1973;
            7'd12: cos_quarter_lut = 12'sd1959;
            7'd13: cos_quarter_lut = 12'sd1944;
            7'd14: cos_quarter_lut = 12'sd1927;
            7'd15: cos_quarter_lut = 12'sd1910;
            7'd16: cos_quarter_lut = 12'sd1891;
            7'd17: cos_quarter_lut = 12'sd1871;
            7'd18: cos_quarter_lut = 12'sd1850;
            7'd19: cos_quarter_lut = 12'sd1828;
            7'd20: cos_quarter_lut = 12'sd1805;
            7'd21: cos_quarter_lut = 12'sd1781;
            7'd22: cos_quarter_lut = 12'sd1756;
            7'd23: cos_quarter_lut = 12'sd1729;
            7'd24: cos_quarter_lut = 12'sd1702;
            7'd25: cos_quarter_lut = 12'sd1674;
            7'd26: cos_quarter_lut = 12'sd1644;
            7'd27: cos_quarter_lut = 12'sd1614;
            7'd28: cos_quarter_lut = 12'sd1582;
            7'd29: cos_quarter_lut = 12'sd1550;
            7'd30: cos_quarter_lut = 12'sd1517;
            7'd31: cos_quarter_lut = 12'sd1483;
            7'd32: cos_quarter_lut = 12'sd1447;
            7'd33: cos_quarter_lut = 12'sd1411;
            7'd34: cos_quarter_lut = 12'sd1375;
            7'd35: cos_quarter_lut = 12'sd1337;
            7'd36: cos_quarter_lut = 12'sd1299;
            7'd37: cos_quarter_lut = 12'sd1259;
            7'd38: cos_quarter_lut = 12'sd1219;
            7'd39: cos_quarter_lut = 12'sd1179;
            7'd40: cos_quarter_lut = 12'sd1137;
            7'd41: cos_quarter_lut = 12'sd1095;
            7'd42: cos_quarter_lut = 12'sd1052;
            7'd43: cos_quarter_lut = 12'sd1009;
            7'd44: cos_quarter_lut = 12'sd965;
            7'd45: cos_quarter_lut = 12'sd920;
            7'd46: cos_quarter_lut = 12'sd875;
            7'd47: cos_quarter_lut = 12'sd830;
            7'd48: cos_quarter_lut = 12'sd783;
            7'd49: cos_quarter_lut = 12'sd737;
            7'd50: cos_quarter_lut = 12'sd690;
            7'd51: cos_quarter_lut = 12'sd642;
            7'd52: cos_quarter_lut = 12'sd594;
            7'd53: cos_quarter_lut = 12'sd546;
            7'd54: cos_quarter_lut = 12'sd497;
            7'd55: cos_quarter_lut = 12'sd449;
            7'd56: cos_quarter_lut = 12'sd399;
            7'd57: cos_quarter_lut = 12'sd350;
            7'd58: cos_quarter_lut = 12'sd300;
            7'd59: cos_quarter_lut = 12'sd251;
            7'd60: cos_quarter_lut = 12'sd201;
            7'd61: cos_quarter_lut = 12'sd151;
            7'd62: cos_quarter_lut = 12'sd100;
            7'd63: cos_quarter_lut = 12'sd50;
            7'd64: cos_quarter_lut = 12'sd0;
            default: cos_quarter_lut = 12'sd0;
        endcase
    endfunction

    // ====================================================================
    // Phase-to-Trigonometric Functions (quadrant folding)
    //
    //   Input : 8-bit phase φ  (upper byte of 16-bit NCO)
    //   Output: cos(2π·φ/256) and sin(2π·φ/256) in Q1.11
    //
    //   Quadrant  φ[7:6]   cos                    sin
    //   ────────  ──────   ────                   ────
    //      0       00      +lut[idx]              +lut[64−idx]
    //      1       01      −lut[64−idx]           +lut[idx]
    //      2       10      −lut[idx]              −lut[64−idx]
    //      3       11      +lut[64−idx]           −lut[idx]
    // ====================================================================
    function automatic sample_t phase_to_cos(input logic [7:0] phase);
        logic [1:0] q;
        logic [6:0] fwd, rev;
        q   = phase[7:6];
        fwd = {1'b0, phase[5:0]};
        rev = 7'd64 - fwd;
        case (q)
            2'b00: phase_to_cos =  cos_quarter_lut(fwd);
            2'b01: phase_to_cos = -cos_quarter_lut(rev);
            2'b10: phase_to_cos = -cos_quarter_lut(fwd);
            2'b11: phase_to_cos =  cos_quarter_lut(rev);
        endcase
    endfunction

    function automatic sample_t phase_to_sin(input logic [7:0] phase);
        logic [1:0] q;
        logic [6:0] fwd, rev;
        q   = phase[7:6];
        fwd = {1'b0, phase[5:0]};
        rev = 7'd64 - fwd;
        case (q)
            2'b00: phase_to_sin =  cos_quarter_lut(rev);
            2'b01: phase_to_sin =  cos_quarter_lut(fwd);
            2'b10: phase_to_sin = -cos_quarter_lut(rev);
            2'b11: phase_to_sin = -cos_quarter_lut(fwd);
        endcase
    endfunction

    // ====================================================================
    // 16-QAM Hard-Decision Slicer
    //
    //   Maps an input sample to the nearest constellation level:
    //     x < −SLICER_TH  →  QAM_NEG3
    //     −SLICER_TH ≤ x < 0  →  QAM_NEG1
    //     0 ≤ x < +SLICER_TH  →  QAM_POS1
    //     x ≥ +SLICER_TH  →  QAM_POS3
    // ====================================================================
    function automatic sample_t qam_slice(input sample_t x);
        if (x < -SLICER_TH)
            qam_slice = QAM_NEG3;
        else if (x < 12'sd0)
            qam_slice = QAM_NEG1;
        else if (x < SLICER_TH)
            qam_slice = QAM_POS1;
        else
            qam_slice = QAM_POS3;
    endfunction

    // ====================================================================
    // NCO Phase Register
    //
    // Initialize with a non-zero phase offset (π/4 = 45°) to force the
    // loop to actively correct from startup. Without this, in a system
    // with zero CFO and zero initial phase error, the loop would idle
    // at zero correction and never demonstrate active tracking.
    //
    // Phase 45° = 32/256 of full circle = 32 × 256 = 8192 in upper byte
    // ====================================================================
    localparam [NCO_W-1:0] NCO_PHASE_INIT = 16'h0000;  // DIAG: 0° frozen

    logic [NCO_W-1:0] nco_phase;
    wire  [7:0]       phase_byte = nco_phase[NCO_W-1 -: 8]; // upper 8 bits

    // ====================================================================
    // Stage 1 — Phase Rotator  (registered on sym_strobe)
    //
    //   CONJUGATE rotation to REMOVE channel phase:
    //     rot_I = sym_I · cos + sym_Q · sin     (4 DSP multiplies)
    //     rot_Q = sym_Q · cos − sym_I · sin
    //
    //   Products are Q2.22 (24-bit).  After add/sub → 25-bit.
    //   Truncated back to Q1.11 with saturation.
    // ====================================================================
    sample_t cos_val, sin_val;
    assign cos_val = phase_to_cos(phase_byte);
    assign sin_val = phase_to_sin(phase_byte);

    // 12×12 = 24-bit products
    wire signed [PRODUCT_WIDTH-1:0] p_ic = sym_I * cos_val;  // I·cos
    wire signed [PRODUCT_WIDTH-1:0] p_qs = sym_Q * sin_val;  // Q·sin
    wire signed [PRODUCT_WIDTH-1:0] p_is = sym_I * sin_val;  // I·sin
    wire signed [PRODUCT_WIDTH-1:0] p_qc = sym_Q * cos_val;  // Q·cos

    // 25-bit add/sub — CONJUGATE rotation (de-rotate by -phase)
    wire signed [PRODUCT_WIDTH:0] rot_I_full = {p_ic[PRODUCT_WIDTH-1], p_ic}
                                             + {p_qs[PRODUCT_WIDTH-1], p_qs};
    wire signed [PRODUCT_WIDTH:0] rot_Q_full = {p_qc[PRODUCT_WIDTH-1], p_qc}
                                             - {p_is[PRODUCT_WIDTH-1], p_is};

    // Truncate Q2.22 → Q1.11 with saturation
    //   Take bits [22:11].  Check guard bits [24:23] for overflow.
    localparam sample_t SAT_POS =  12'sd2047;
    localparam sample_t SAT_NEG = -12'sd2048;

    function automatic sample_t trunc_sat(input logic signed [PRODUCT_WIDTH:0] val);
        logic sign;
        logic guard_ok;
        sign     = val[PRODUCT_WIDTH];
        guard_ok = (val[PRODUCT_WIDTH:FRAC_BITS+DATA_WIDTH] == '0) ||
                   (&val[PRODUCT_WIDTH:FRAC_BITS+DATA_WIDTH]);
        if (!guard_ok)
            trunc_sat = sign ? SAT_NEG : SAT_POS;
        else
            trunc_sat = val[FRAC_BITS + DATA_WIDTH - 1 : FRAC_BITS];
    endfunction

    // Registered rotated output
    sample_t rot_I_r, rot_Q_r;
    logic    rot_valid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rot_I_r   <= '0;
            rot_Q_r   <= '0;
            rot_valid <= 1'b0;
        end else begin
            rot_valid <= sym_strobe;
            if (sym_strobe) begin
                rot_I_r <= trunc_sat(rot_I_full);
                rot_Q_r <= trunc_sat(rot_Q_full);
            end
        end
    end

    // ====================================================================
    // Stage 2 — Error Computation, Loop Filter, NCO Update
    //   All triggered by rot_valid (one cycle after sym_strobe).
    // ====================================================================

    // --- Slicer (combinational on registered rot) ---
    sample_t I_hat, Q_hat;
    assign I_hat = qam_slice(rot_I_r);
    assign Q_hat = qam_slice(rot_Q_r);

    // --- DD Phase Error (cross-product) ---
    //   e = rot_Q · I_hat − rot_I · Q_hat   (standard DD cross-product)
    //   Sign convention: positive error when NCO lags channel phase,
    //   ensuring negative feedback (NCO advances to catch up).
    //   Products are 24-bit (Q2.22).  Difference is 25-bit.
    //   We take bits [23:12] ≈ Q2.10 as a 12-bit error for the loop filter.
    wire signed [PRODUCT_WIDTH-1:0] pe_iq = rot_I_r * Q_hat;
    wire signed [PRODUCT_WIDTH-1:0] pe_qi = rot_Q_r * I_hat;
    wire signed [PRODUCT_WIDTH:0]   pe_full = {pe_qi[PRODUCT_WIDTH-1], pe_qi}
                                            - {pe_iq[PRODUCT_WIDTH-1], pe_iq};

    // Normalise error: shift out the lower frac bits for the loop filter.
    //   pe_full is ~Q2.22 (25 bits).  Taking [23:12] gives ~12-bit dynamic range.
    wire signed [DATA_WIDTH-1:0] phase_err =
        pe_full[PRODUCT_WIDTH-1 -: DATA_WIDTH];

    // --- PI Loop Filter (Type-2) ---
    //   ω += Ki · e          (frequency integrator)
    //   θ += ω + Kp · e      (phase update)
    //
    //   Anti-windup: ω clamped to ±FREQ_BOUND.
    //   Holdoff: loop filter is frozen for the first COSTAS_HOLDOFF
    //   symbols to prevent the matched-filter fill-up transient from
    //   biasing the frequency integrator.
    localparam int COSTAS_HOLDOFF = 30;
    localparam signed [NCO_W-1:0] FREQ_BOUND = (1 <<< (NCO_W - 3)) - 1; // ±8191

    logic signed [NCO_W-1:0] omega;          // estimated frequency offset
    logic [7:0]              costas_holdcnt;  // holdoff counter
    wire                     costas_active = (costas_holdcnt >= COSTAS_HOLDOFF[7:0]);
    wire  signed [NCO_W-1:0] err_ext  = NCO_W'($signed(phase_err));

    // Truncate-toward-zero helper: avoids negative bias from Verilog’s
    // arithmetic right shift (>>>), which rounds toward −∞.
    //   −69 >>> 6 = −2  but  +69 >>> 6 = +1  (biased)
    //   truncz(−69,6) = −1, truncz(+69,6) = +1  (symmetric)

    // Gear-shifted Kp and Ki with truncation-toward-zero.
    //   Two fixed-shift paths selected by a symbol-count comparator.
    //   Synthesises to a pair of 2:1 muxes per bit — negligible LUT cost.
    wire gear_tracking = (costas_holdcnt >= GEAR_SHIFT_SYM[7:0]);

    // Proportional (Kp)
    wire signed [NCO_W-1:0] kp_acq = (err_ext >= 0) ? (err_ext >>> KP_SHIFT_ACQ)
                                                     : -((-err_ext) >>> KP_SHIFT_ACQ);
    wire signed [NCO_W-1:0] kp_trk = (err_ext >= 0) ? (err_ext >>> KP_SHIFT_TRK)
                                                     : -((-err_ext) >>> KP_SHIFT_TRK);
    wire signed [NCO_W-1:0] kp_term = gear_tracking ? kp_trk : kp_acq;

    // Integrator (Ki) — already gear-shifted via gear_tracking above
    wire signed [NCO_W-1:0] ki_acq = (err_ext >= 0) ? (err_ext >>> KI_SHIFT_ACQ)
                                                     : -((-err_ext) >>> KI_SHIFT_ACQ);
    wire signed [NCO_W-1:0] ki_trk = (err_ext >= 0) ? (err_ext >>> KI_SHIFT_TRK)
                                                     : -((-err_ext) >>> KI_SHIFT_TRK);
    wire signed [NCO_W-1:0] ki_term   = gear_tracking ? ki_trk : ki_acq;
    wire signed [NCO_W-1:0] omega_next = omega + ki_term;

    // Output register
    sample_t demod_I_r, demod_Q_r;
    logic    demod_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nco_phase      <= NCO_PHASE_INIT;  // Start with phase offset
            omega          <= '0;
            costas_holdcnt <= '0;
            demod_I_r      <= '0;
            demod_Q_r      <= '0;
            demod_valid_r  <= 1'b0;
        end else begin
            demod_valid_r <= rot_valid;

            if (rot_valid) begin
                // Always output the rotated constellation
                demod_I_r <= rot_I_r;
                demod_Q_r <= rot_Q_r;

                // Holdoff counter (saturates at 255)
                if (costas_holdcnt < 8'd255)
                    costas_holdcnt <= costas_holdcnt + 1'b1;

                // === DIAGNOSTIC: NCO FROZEN ===
                // Freeze NCO and omega to test rotator passthrough.
                // With phase=0: cos=2047, sin=0 → identity rotation.
                // Mode 3 should show 16 points if rotator works.
                // Remove this block and uncomment below to re-enable loop.
                nco_phase <= '0;
                omega     <= '0;

                // --- NORMAL LOOP (disabled for diagnostic) ---
                // if (costas_active) begin
                //     nco_phase <= nco_phase + NCO_W'(omega) + NCO_W'(kp_term);
                //     if (err_abs > DEAD_ZONE[DATA_WIDTH-1:0]) begin
                //         if (omega_next > FREQ_BOUND)
                //             omega <= FREQ_BOUND;
                //         else if (omega_next < -FREQ_BOUND)
                //             omega <= -FREQ_BOUND;
                //         else
                //             omega <= omega_next;
                //     end
                // end
            end
        end
    end

    // ====================================================================
    // Lock Detector
    //
    //   Exponential moving average of |phase_err|:
    //     avg = avg + (|e| − avg) >> LOCK_AVG_SHIFT
    //
    //   Lock declared when avg < LOCK_THRESHOLD *and* a minimum number
    //   of symbols have been processed (holdoff prevents false lock
    //   during the initial acquisition transient).
    //
    //   IMPORTANT: The EMA delta (|e| − avg) must be computed in signed
    //   arithmetic to avoid unsigned wrap-around when |e| < avg.
    // ====================================================================
    logic [DATA_WIDTH-1:0] err_abs;
    logic [DATA_WIDTH-1:0] lock_avg;
    logic [7:0]            lock_holdoff;   // Symbol counter for holdoff

    assign err_abs = (phase_err < 0) ? DATA_WIDTH'(-phase_err) : DATA_WIDTH'(phase_err);

    // Signed EMA delta (13-bit to hold full range without wrap)
    wire signed [DATA_WIDTH:0] ema_diff =
        $signed({1'b0, err_abs}) - $signed({1'b0, lock_avg});
    wire signed [DATA_WIDTH:0] ema_step = ema_diff >>> LOCK_AVG_SHIFT;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lock_avg    <= {DATA_WIDTH{1'b1}};   // Start high (unlocked)
            lock_holdoff <= '0;
        end else if (rot_valid) begin
            // Holdoff counter (saturates at 255)
            if (lock_holdoff < 8'd255)
                lock_holdoff <= lock_holdoff + 1'b1;

            // Signed EMA update with floor at 0
            if ($signed({1'b0, lock_avg}) + ema_step < 0)
                lock_avg <= '0;
            else
                lock_avg <= lock_avg + DATA_WIDTH'(ema_step);
        end
    end

    // Lock requires holdoff period (≥100 symbols) AND low average error
    assign demod_lock = (lock_avg < LOCK_THRESHOLD[DATA_WIDTH-1:0]) &&
                        (lock_holdoff >= 8'd100);

    // ====================================================================
    // Output
    // ====================================================================
    assign demod_I     = demod_I_r;
    assign demod_Q     = demod_Q_r;
    assign demod_valid = demod_valid_r;

endmodule : costas_loop
