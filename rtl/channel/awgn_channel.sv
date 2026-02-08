// ============================================================================
// G-DSP Engine — AWGN Channel Top-Level
// ============================================================================
// Models an additive white Gaussian noise (AWGN) channel for in-FPGA BER
// testing.  Receives the baseband I/Q signals from the transmitter,
// adds independent Gaussian noise to each branch, and delivers the
// corrupted signals to the receiver.
//
// ---- Overflow Management ----
//
//   The core operation is:  rx = tx + noise
//
//   Both tx and noise are Q1.11 (12-bit signed, range [−2048, +2047]).
//   Their sum can range from −4096 to +4094 — a 13-bit signed value.
//   We therefore compute the sum in 13-bit extended precision, then
//   apply saturation arithmetic to clamp back to 12-bit Q1.11.
//
//   Why saturation instead of simple truncation?
//   - Truncation (discarding the MSB) causes catastrophic sign inversion
//     when the sum overflows.  A +2100 value would wrap to a large
//     negative number, injecting massive distortion.
//   - Saturation clips to ±2047/−2048, introducing mild compression
//     that only affects samples at extreme signal+noise values.  This
//     mirrors real-world DAC/ADC clipping behaviour.
//   - For Eb/No ≥ 10 dB, the probability of saturation is < 0.1%,
//     making the distortion negligible for BER measurements.
//
// ---- Interface ----
//
//   noise_magnitude [7:0]:  unsigned control register (0 = no noise,
//     255 = maximum noise).  In a final SoC this register would be
//     memory-mapped for software control of the Eb/No sweep.
//
// Latency: 3 cycles (noise generator) + 1 cycle (addition) = 4 cycles
// ============================================================================

module channel_top
    import gdsp_pkg::*;
(
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       en,              // Global enable

    // --- TX interface (from tx_top) ---
    input  sample_t                    tx_I,            // Clean I (Q1.11)
    input  sample_t                    tx_Q,            // Clean Q (Q1.11)
    input  logic                       tx_valid,        // TX valid strobe

    // --- Noise control ---
    input  logic [NOISE_MAG_WIDTH-1:0] noise_magnitude, // 0..255

    // --- RX interface (to receiver / HDMI) ---
    output sample_t                    rx_I,            // Noisy I (Q1.11)
    output sample_t                    rx_Q,            // Noisy Q (Q1.11)
    output logic                       rx_valid         // RX valid strobe
);

    // -----------------------------------------------------------------------
    // Noise Generators — one per I/Q channel for independence
    //
    //   Using two separate awgn_generator instances ensures the I-channel
    //   and Q-channel noise are statistically independent (different LFSR
    //   seed sets are guaranteed because the second instance gets different
    //   initial seeds via the generate block inside awgn_generator).
    //
    //   Alternative: a single generator with time-multiplexed output.
    //   Rejected because it would halve the effective sample rate or
    //   require double-clocking.
    // -----------------------------------------------------------------------
    sample_t noise_I, noise_Q;
    logic    noise_I_valid, noise_Q_valid;

    awgn_generator #(.INSTANCE_ID(0)) u_noise_I (
        .clk             (clk),
        .rst_n           (rst_n),
        .en              (tx_valid),
        .noise_magnitude (noise_magnitude),
        .noise_out       (noise_I),
        .noise_valid     (noise_I_valid)
    );

    awgn_generator #(.INSTANCE_ID(1)) u_noise_Q (
        .clk             (clk),
        .rst_n           (rst_n),
        .en              (tx_valid),
        .noise_magnitude (noise_magnitude),
        .noise_out       (noise_Q),
        .noise_valid     (noise_Q_valid)
    );

    // -----------------------------------------------------------------------
    // Delay TX samples to align with noise generator latency (3 cycles)
    //
    //   The awgn_generator has 3-cycle pipeline latency.  We must delay
    //   the clean TX signal by the same amount so that the addition
    //   tx + noise is sample-aligned.
    // -----------------------------------------------------------------------
    sample_t tx_I_d [0:2];
    sample_t tx_Q_d [0:2];
    logic    tx_valid_d [0:2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 3; i++) begin
                tx_I_d[i]     <= '0;
                tx_Q_d[i]     <= '0;
                tx_valid_d[i] <= 1'b0;
            end
        end else begin
            tx_I_d[0]     <= tx_I;
            tx_Q_d[0]     <= tx_Q;
            tx_valid_d[0] <= tx_valid;
            for (int i = 1; i < 3; i++) begin
                tx_I_d[i]     <= tx_I_d[i-1];
                tx_Q_d[i]     <= tx_Q_d[i-1];
                tx_valid_d[i] <= tx_valid_d[i-1];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Saturating Addition:  rx = clamp(tx_delayed + noise)
    //
    //   Both operands are 12-bit signed (Q1.11).
    //   Sum is computed in 13 bits to capture the full range, then
    //   saturated back to 12 bits.
    //
    //   13-bit sum range: [−4096, +4094]
    //   Q1.11 range:      [−2048, +2047]
    //
    //   Saturation logic:
    //     if sum > +2047:  result = +2047  (SAT_POS)
    //     if sum < −2048:  result = −2048  (SAT_NEG)
    //     else:            result = sum[11:0]
    // -----------------------------------------------------------------------
    localparam sample_t SAT_POS =  12'sd2047;
    localparam sample_t SAT_NEG = -12'sd2048;

    logic signed [DATA_WIDTH:0] sum_I, sum_Q;  // 13-bit signed
    sample_t rx_I_sat, rx_Q_sat;

    assign sum_I = {tx_I_d[2][DATA_WIDTH-1], tx_I_d[2]} +
                   {noise_I[DATA_WIDTH-1], noise_I};
    assign sum_Q = {tx_Q_d[2][DATA_WIDTH-1], tx_Q_d[2]} +
                   {noise_Q[DATA_WIDTH-1], noise_Q};

    // I-channel saturation
    always_comb begin
        if (sum_I > 13'sd2047)
            rx_I_sat = SAT_POS;
        else if (sum_I < -13'sd2048)
            rx_I_sat = SAT_NEG;
        else
            rx_I_sat = sum_I[DATA_WIDTH-1:0];
    end

    // Q-channel saturation
    always_comb begin
        if (sum_Q > 13'sd2047)
            rx_Q_sat = SAT_POS;
        else if (sum_Q < -13'sd2048)
            rx_Q_sat = SAT_NEG;
        else
            rx_Q_sat = sum_Q[DATA_WIDTH-1:0];
    end

    // -----------------------------------------------------------------------
    // Output register
    // -----------------------------------------------------------------------
    sample_t rx_I_r, rx_Q_r;
    logic    rx_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_I_r     <= '0;
            rx_Q_r     <= '0;
            rx_valid_r <= 1'b0;
        end else begin
            rx_I_r     <= rx_I_sat;
            rx_Q_r     <= rx_Q_sat;
            rx_valid_r <= noise_I_valid & tx_valid_d[2];
        end
    end

    assign rx_I     = rx_I_r;
    assign rx_Q     = rx_Q_r;
    assign rx_valid = rx_valid_r;

endmodule : channel_top

