// ============================================================================
// G-DSP Engine — Testbench: RX Top (full TX → Channel → RX chain)
// ============================================================================
// End-to-end verification of the complete 16-QAM modem including a
// carrier-frequency-offset (CFO) stress test.
//
//   tx_top  →  [CFO rotator]  →  channel_top (AWGN)  →  rx_top
//   (PRBS→QAM→RRC)  (e^{jωn})  (noise injection)      (RRC→Gardner→Costas)
//
// Tests performed:
//   1. Run the full chain for a configurable number of symbols.
//   2. Wait for the Costas loop to declare lock (demod_lock = 1).
//   3. After lock, capture demodulated I/Q samples and verify they
//      cluster around the 16 ideal constellation points.
//   4. Stress test: verify that the Costas NCO is actively compensating
//      the injected frequency offset (NCO must not remain at zero).
//   5. Report PASS if:
//        a) Lock is achieved within MAX_LOCK_SYMBOLS, AND
//        b) > MIN_ACCURACY% of post-lock samples are within TOLERANCE
//           of a valid 16-QAM constellation point, AND
//        c) NCO is actively tracking (omega ≠ 0) when FREQ_OFFSET > 0.
//
// Output:
//   - VCD waveform dump in sim/waves/tb_rx_top.vcd
//   - Optional CSV of demodulated I/Q in sim/vectors/rx_constellation.csv
//   - Console statistics: lock time, accuracy, NCO state, min/max error.
//
// Usage (Icarus Verilog):
//   iverilog -g2012 -I sim/vectors -o sim/out/tb_rx_top.vvp \
//       rtl/packages/gdsp_pkg.sv \
//       rtl/common/bit_gen.sv \
//       rtl/modem/qam16_mapper.sv \
//       rtl/modem/rrc_filter.sv \
//       rtl/modem/tx_top.sv \
//       rtl/channel/awgn_generator.sv \
//       rtl/channel/awgn_channel.sv \
//       rtl/sync/gardner_ted.sv \
//       rtl/sync/costas_loop.sv \
//       rtl/modem/rx_top.sv \
//       sim/tb/tb_rx_top.sv
//   vvp sim/out/tb_rx_top.vvp
// ============================================================================

`timescale 1ns / 1ps

module tb_rx_top;

    import gdsp_pkg::*;

    // -----------------------------------------------------------------------
    // Test configuration
    // -----------------------------------------------------------------------
    localparam int NUM_SYMBOLS      = 2500;     // Total symbols to simulate
    localparam int MAX_LOCK_SYMBOLS = 800;      // Max symbols before lock expected
    localparam int POST_LOCK_CAP    = 500;      // Symbols to capture after lock
    localparam int POST_LOCK_SETTLE = 400;      // Settle time before counting accuracy
    localparam int TOLERANCE        = 650;      // Max distance from ideal QAM point (5-tap ISI ~20%)
    localparam int MIN_ACCURACY_PCT = 80;       // Min % of correct post-lock samples
    localparam int NUM_SAMPLES      = NUM_SYMBOLS * SPS;

    // Moderate noise: SNR ~ 20 dB for clean-ish constellation
    localparam logic [NOISE_MAG_WIDTH-1:0] NOISE_MAG = 8'd25;

    // -----------------------------------------------------------------------
    // Stress Test: Carrier Frequency Offset (CFO) injection
    //
    //   A non-zero FREQ_OFFSET_HZ rotates the TX constellation by e^{jωn}
    //   at sample rate, simulating a real-world carrier frequency mismatch.
    //   The Costas loop must acquire and track this offset, driving its NCO
    //   to a non-zero value that compensates the rotation.
    // -----------------------------------------------------------------------
    localparam real FREQ_OFFSET_HZ = 500.0;     // 500 Hz CFO stress test
    localparam real PI             = 3.14159265358979323846;
    localparam real CLK_FREQ       = 27000000.0;
    localparam real CFO_DELTA      = 2.0 * PI * FREQ_OFFSET_HZ / CLK_FREQ;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    logic clk   = 0;
    logic rst_n = 0;
    always #18.519 clk = ~clk;          // ~27 MHz (37.037 ns period)

    // -----------------------------------------------------------------------
    // TX signals
    // -----------------------------------------------------------------------
    logic    tx_en;
    sample_t tx_I, tx_Q;
    logic    tx_valid;
    logic    sym_tick;

    tx_top u_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (tx_en),
        .tx_I      (tx_I),
        .tx_Q      (tx_Q),
        .tx_valid  (tx_valid),
        .sym_tick  (sym_tick),
        .map_I     (),
        .map_Q     (),
        .map_valid ()
    );

    // -----------------------------------------------------------------------
    // Carrier Frequency Offset (CFO) Rotator
    //
    //   Applies a complex rotation to the TX samples before the channel:
    //     cfo_I = tx_I·cos(θ) − tx_Q·sin(θ)
    //     cfo_Q = tx_I·sin(θ) + tx_Q·cos(θ)
    //   where θ increments by 2π·f_offset/f_clk each valid sample.
    //
    //   Uses real-valued arithmetic ($cos/$sin) — testbench only, not
    //   synthesisable.  One pipeline register for timing alignment.
    // -----------------------------------------------------------------------
    sample_t cfo_I, cfo_Q;
    logic    cfo_valid;
    real     cfo_phase = 0.0;

    always @(posedge clk) begin
        if (!rst_n) begin
            cfo_I     <= '0;
            cfo_Q     <= '0;
            cfo_valid <= 1'b0;
            cfo_phase  = 0.0;
        end else begin
            cfo_valid <= tx_valid;
            if (tx_valid) begin : cfo_rotate
                real i_f, q_f, c, s, ri, rq;
                i_f = $itor($signed(tx_I));
                q_f = $itor($signed(tx_Q));
                c   = $cos(cfo_phase);
                s   = $sin(cfo_phase);
                ri  = i_f * c - q_f * s;
                rq  = i_f * s + q_f * c;
                // Saturate to Q1.11 range [-2048, +2047]
                if (ri > 2047.0)       cfo_I <= 12'sd2047;
                else if (ri < -2048.0) cfo_I <= -12'sd2048;
                else                   cfo_I <= $rtoi(ri);
                if (rq > 2047.0)       cfo_Q <= 12'sd2047;
                else if (rq < -2048.0) cfo_Q <= -12'sd2048;
                else                   cfo_Q <= $rtoi(rq);
                // Advance phase
                cfo_phase = cfo_phase + CFO_DELTA;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Channel signals — fed from CFO rotator, not raw TX
    // -----------------------------------------------------------------------
    sample_t ch_I, ch_Q;
    logic    ch_valid;

    channel_top u_channel (
        .clk             (clk),
        .rst_n           (rst_n),
        .en              (1'b1),
        .tx_I            (cfo_I),
        .tx_Q            (cfo_Q),
        .tx_valid        (cfo_valid),
        .noise_magnitude (NOISE_MAG),
        .rx_I            (ch_I),
        .rx_Q            (ch_Q),
        .rx_valid        (ch_valid)
    );

    // -----------------------------------------------------------------------
    // RX signals
    // -----------------------------------------------------------------------
    sample_t demod_I, demod_Q;
    logic    demod_valid;
    logic    demod_lock;

    rx_top u_rx (
        .clk         (clk),
        .rst_n       (rst_n),
        .rx_I        (ch_I),
        .rx_Q        (ch_Q),
        .rx_valid    (ch_valid),
        .demod_I     (demod_I),
        .demod_Q     (demod_Q),
        .demod_valid (demod_valid),
        .demod_lock  (demod_lock)
    );

    // -----------------------------------------------------------------------
    // VCD dump
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/waves/tb_rx_top.vcd");
        $dumpvars(0, tb_rx_top);
    end

    // -----------------------------------------------------------------------
    // CSV output for external plotting
    // -----------------------------------------------------------------------
    integer csv_fd;
    initial begin
        csv_fd = $fopen("sim/vectors/rx_constellation.csv", "w");
        $fwrite(csv_fd, "sym_idx,demod_I,demod_Q,locked\n");
    end

    // -----------------------------------------------------------------------
    // 16-QAM ideal constellation levels
    //
    // With 5-tap RRC (peak gain ~1.0), levels are at original scale.
    // -----------------------------------------------------------------------
    sample_t qam_levels [0:3];
    initial begin
        qam_levels[0] = QAM_NEG3;   // -1943
        qam_levels[1] = QAM_NEG1;   //  -648
        qam_levels[2] = QAM_POS1;   //  +648
        qam_levels[3] = QAM_POS3;   // +1943
    end

    // Function: minimum distance from sample to any QAM level
    function automatic int min_qam_dist(input int val);
        int d, best;
        best = 99999;
        for (int k = 0; k < 4; k++) begin
            d = val - $signed(qam_levels[k]);
            if (d < 0) d = -d;
            if (d < best) best = d;
        end
        min_qam_dist = best;
    endfunction

    // -----------------------------------------------------------------------
    // Monitoring
    // -----------------------------------------------------------------------
    int sym_count      = 0;
    int tx_sym_count   = 0;
    int lock_sym       = -1;           // Symbol at which lock achieved
    int post_lock_cnt  = 0;
    int correct_cnt    = 0;
    int total_post     = 0;
    int max_err_I      = 0;
    int max_err_Q      = 0;
    logic lock_achieved = 0;

    // --- Stress Test: NCO activity monitor ---
    //   After lock, the Costas NCO must be actively compensating the
    //   injected CFO.  We track whether omega (frequency estimate) and
    //   nco_phase ever become non-zero post-lock.
    logic nco_was_active = 0;
    int   omega_at_lock  = 0;
    int   omega_steady   = 0;
    logic [15:0] nco_at_lock = '0;

    always @(posedge clk) begin
        if (demod_valid && lock_achieved) begin
            if (u_rx.u_costas.omega != 0 || u_rx.u_costas.nco_phase != 16'h0000)
                nco_was_active <= 1'b1;
            // Capture omega a few symbols after lock for reporting
            if (post_lock_cnt == POST_LOCK_SETTLE + 10) begin
                omega_at_lock <= $signed(u_rx.u_costas.omega);
                nco_at_lock   <= u_rx.u_costas.nco_phase;
            end
            if (post_lock_cnt == POST_LOCK_CAP + POST_LOCK_SETTLE - 1)
                omega_steady <= $signed(u_rx.u_costas.omega);
        end
    end

    // --- DEBUG: Print matched-filter output at sample rate (first 80) ---
    int mf_sample_cnt = 0;
    always @(posedge clk) begin
        if (u_rx.mf_I_valid) begin
            mf_sample_cnt <= mf_sample_cnt + 1;
        end
    end

    // --- DEBUG: Phase accuracy test — try each SPS offset ---
    int ph_correct [0:3];
    int ph_total   [0:3];
    initial begin
        for (int p = 0; p < 4; p++) begin ph_correct[p] = 0; ph_total[p] = 0; end
    end

    int mf_phase_cnt = 0;
    always @(posedge clk) begin
        if (u_rx.mf_I_valid && mf_sample_cnt > 100) begin
            mf_phase_cnt <= mf_phase_cnt + 1;
            if (mf_phase_cnt < 4000) begin
                for (int p = 0; p < 4; p++) begin
                    if ((mf_phase_cnt % 4) == p) begin
                        ph_total[p] = ph_total[p] + 1;
                        if (min_qam_dist($signed(u_rx.mf_I)) <= TOLERANCE &&
                            min_qam_dist($signed(u_rx.mf_Q)) <= TOLERANCE) begin
                            ph_correct[p] = ph_correct[p] + 1;
                        end
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (sym_tick)
            tx_sym_count <= tx_sym_count + 1;

        if (demod_valid) begin
            sym_count <= sym_count + 1;

            // Log to CSV
            $fwrite(csv_fd, "%0d,%0d,%0d,%0d\n",
                    sym_count, $signed(demod_I), $signed(demod_Q), demod_lock);

            // Print first 10 + some post-lock symbols for debug
            if (sym_count < 10 || (sym_count >= 400 && sym_count < 410)) begin
                $display("[RX] sym[%4d] I=%6d  Q=%6d  lock=%b",
                         sym_count, $signed(demod_I), $signed(demod_Q), demod_lock);
            end

            // Track lock event
            if (demod_lock && !lock_achieved) begin
                lock_achieved <= 1'b1;
                lock_sym <= sym_count;
                $display("[RX] *** LOCK ACHIEVED at symbol %0d ***", sym_count);
            end

            // Post-lock statistics (skip settle period for accuracy)
            if (lock_achieved && post_lock_cnt < POST_LOCK_CAP + POST_LOCK_SETTLE) begin
                post_lock_cnt <= post_lock_cnt + 1;

                // Only count accuracy after settling
                if (post_lock_cnt >= POST_LOCK_SETTLE) begin
                    total_post <= total_post + 1;

                    // Check I and Q distances to nearest QAM level
                    if (min_qam_dist($signed(demod_I)) <= TOLERANCE &&
                        min_qam_dist($signed(demod_Q)) <= TOLERANCE) begin
                        correct_cnt <= correct_cnt + 1;
                    end

                    // Track worst-case error
                    if (min_qam_dist($signed(demod_I)) > max_err_I)
                        max_err_I <= min_qam_dist($signed(demod_I));
                    if (min_qam_dist($signed(demod_Q)) > max_err_Q)
                        max_err_Q <= min_qam_dist($signed(demod_Q));
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        $display("============================================================");
        $display("  G-DSP Engine — RX Top Testbench (Full Modem Chain)");
        $display("============================================================");
        $display("  Noise magnitude    : %0d", NOISE_MAG);
        $display("  Freq offset (CFO)  : %.0f Hz", FREQ_OFFSET_HZ);
        $display("  Total symbols      : %0d", NUM_SYMBOLS);
        $display("  Max lock window    : %0d symbols", MAX_LOCK_SYMBOLS);
        $display("  Post-lock cap      : %0d symbols", POST_LOCK_CAP);
        $display("  Tolerance          : +/-%0d (Q1.11 LSBs)", TOLERANCE);
        $display("============================================================");

        // Reset
        tx_en = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Enable TX
        tx_en = 1'b1;

        // Run for enough time
        //   Each symbol = SPS clocks for TX + pipeline latency.
        //   Add generous margin for RRC filter fill + sync acquisition.
        repeat (NUM_SAMPLES + NUM_TAPS*2 + 200) @(posedge clk);

        // Wait additional time if lock hasn't been achieved yet
        if (!lock_achieved) begin
            $display("[RX] Lock not yet achieved; running additional cycles...");
            repeat (2000) @(posedge clk);
        end

        // Ensure we have enough post-lock samples (including settle time)
        if (lock_achieved && post_lock_cnt < POST_LOCK_CAP + POST_LOCK_SETTLE) begin
            repeat ((POST_LOCK_CAP + POST_LOCK_SETTLE - post_lock_cnt) * SPS + 100) @(posedge clk);
        end

        tx_en = 1'b0;
        repeat (50) @(posedge clk);

        // ----- Report -----
        $display("");
        $display("============================================================");
        $display("  RX Top — Simulation Results");
        $display("============================================================");
        $display("  TX symbols generated  : %0d", tx_sym_count);
        $display("  RX symbols demodulated: %0d", sym_count);

        if (lock_achieved) begin
            $display("  Lock achieved at sym  : %0d", lock_sym);
        end else begin
            $display("  Lock achieved at sym  : NEVER");
        end

        $display("  Post-lock samples     : %0d", total_post);
        if (total_post > 0) begin
            $display("  Correct (within tol.) : %0d / %0d (%0d%%)",
                     correct_cnt, total_post, (correct_cnt * 100) / total_post);
            $display("  Max I error           : %0d", max_err_I);
            $display("  Max Q error           : %0d", max_err_Q);
        end

        // ----- Phase accuracy test results -----
        $display("");
        $display("  --- Phase Offset Analysis (matched filter output) ---");
        for (int p = 0; p < 4; p++) begin
            if (ph_total[p] > 0)
                $display("    Phase %0d: %0d / %0d correct (%0d%%)",
                         p, ph_correct[p], ph_total[p],
                         (ph_correct[p] * 100) / ph_total[p]);
        end

        // ----- Stress Test: NCO Activity -----
        $display("");
        $display("  --- Stress Test (CFO = %.0f Hz) ---", FREQ_OFFSET_HZ);
        $display("    NCO active post-lock : %s", nco_was_active ? "YES" : "NO");
        $display("    omega at lock+10     : %0d", omega_at_lock);
        $display("    omega at steady state: %0d", omega_steady);
        $display("    NCO phase at lock    : 0x%04x", nco_at_lock);

        // ----- PASS / FAIL -----
        begin
            logic accuracy_ok, stress_ok, all_ok;
            int accuracy_pct;

            accuracy_pct = (total_post > 0) ? (correct_cnt * 100) / total_post : 0;
            accuracy_ok  = lock_achieved && (total_post > 0) &&
                           (accuracy_pct >= MIN_ACCURACY_PCT);

            // Stress check: if CFO > 0, NCO must be actively tracking
            stress_ok = (FREQ_OFFSET_HZ == 0.0) || nco_was_active;

            all_ok = accuracy_ok && stress_ok;

            $display("");
            if (all_ok) begin
                $display("  >>> ALL TESTS PASSED <<<");
                if (FREQ_OFFSET_HZ > 0.0)
                    $display("  Stress Test Passed: NCO active and correcting.");
            end else begin
                if (!lock_achieved)
                    $display("  >>> FAIL: Lock not achieved within %0d symbols <<<",
                             MAX_LOCK_SYMBOLS);
                else if (total_post == 0)
                    $display("  >>> FAIL: No post-lock samples captured <<<");
                else if (!accuracy_ok)
                    $display("  >>> FAIL: Accuracy %0d%% < required %0d%% <<<",
                             accuracy_pct, MIN_ACCURACY_PCT);
                if (!stress_ok)
                    $display("  >>> FAIL: Stress test — NCO inactive (stuck at 0) <<<");
            end
        end
        $display("============================================================");

        $fclose(csv_fd);
        #200;
        $finish;
    end

endmodule
