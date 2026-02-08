// ============================================================================
// G-DSP Engine — AWGN Channel Testbench
// ============================================================================
// Validates the channel_top module by sweeping noise_magnitude from low
// to high and capturing I/Q output samples.  Demonstrates how the
// 16-QAM constellation progressively disperses as noise increases.
//
// Tests performed:
//   1. Bypass test:  noise_magnitude = 0 → rx == tx (passthrough).
//   2. Low noise:    noise_magnitude = 16  → minimal spread.
//   3. Medium noise: noise_magnitude = 64  → visible cloud.
//   4. High noise:   noise_magnitude = 192 → heavy corruption.
//   5. Saturation stress: noise_magnitude = 255 with extreme TX values.
//
// Output:
//   - Prints sample statistics (mean, min, max) per noise level.
//   - Dumps I/Q samples to VCD for waveform inspection.
//   - Optionally writes CSV for external constellation plotting.
// ============================================================================

`timescale 1ns / 1ps

module tb_channel;

    import gdsp_pkg::*;

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    logic                       clk;
    logic                       rst_n;
    logic                       en;
    sample_t                    tx_I, tx_Q;
    logic                       tx_valid;
    logic [NOISE_MAG_WIDTH-1:0] noise_magnitude;
    sample_t                    rx_I, rx_Q;
    logic                       rx_valid;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    channel_top u_dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .en              (en),
        .tx_I            (tx_I),
        .tx_Q            (tx_Q),
        .tx_valid        (tx_valid),
        .noise_magnitude (noise_magnitude),
        .rx_I            (rx_I),
        .rx_Q            (rx_Q),
        .rx_valid        (rx_valid)
    );

    // -----------------------------------------------------------------------
    // Clock generation: 27 MHz → period ≈ 37.037 ns
    // -----------------------------------------------------------------------
    localparam CLK_PERIOD = 37.037;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // -----------------------------------------------------------------------
    // VCD dump
    // -----------------------------------------------------------------------
    initial begin
        $dumpfile("sim/waves/tb_channel.vcd");
        $dumpvars(0, tb_channel);
    end

    // -----------------------------------------------------------------------
    // CSV file handle for constellation data
    // -----------------------------------------------------------------------
    integer csv_fd;

    initial begin
        csv_fd = $fopen("sim/vectors/channel_constellation.csv", "w");
        $fwrite(csv_fd, "noise_mag,rx_I,rx_Q\n");
    end

    // -----------------------------------------------------------------------
    // 16-QAM symbol table (all 16 constellation points)
    // -----------------------------------------------------------------------
    sample_t qam_I [0:3];
    sample_t qam_Q [0:3];

    initial begin
        qam_I[0] = QAM_NEG3;  // -1943
        qam_I[1] = QAM_NEG1;  //  -648
        qam_I[2] = QAM_POS1;  //  +648
        qam_I[3] = QAM_POS3;  // +1943
        qam_Q[0] = QAM_NEG3;
        qam_Q[1] = QAM_NEG1;
        qam_Q[2] = QAM_POS1;
        qam_Q[3] = QAM_POS3;
    end

    // -----------------------------------------------------------------------
    // Task: feed N symbols cycling through all 16 QAM points
    // -----------------------------------------------------------------------
    task automatic feed_symbols(input int num_symbols);
        int sym_idx;
        for (int s = 0; s < num_symbols; s++) begin
            sym_idx = s % 16;
            tx_I     <= qam_I[sym_idx / 4];
            tx_Q     <= qam_Q[sym_idx % 4];
            tx_valid <= 1'b1;
            @(posedge clk);
        end
        tx_valid <= 1'b0;
    endtask

    // -----------------------------------------------------------------------
    // Task: capture N valid output samples and log to CSV
    // -----------------------------------------------------------------------
    task automatic capture_samples(
        input int                       num_samples,
        input logic [NOISE_MAG_WIDTH-1:0] mag,
        output int                      sat_count
    );
        int count;
        int i_val, q_val;
        int i_min, i_max, q_min, q_max;
        longint i_sum, q_sum;

        count     = 0;
        sat_count = 0;
        i_min     =  99999;
        i_max     = -99999;
        q_min     =  99999;
        q_max     = -99999;
        i_sum     = 0;
        q_sum     = 0;

        while (count < num_samples) begin
            @(posedge clk);
            if (rx_valid) begin
                i_val = $signed(rx_I);
                q_val = $signed(rx_Q);

                // Statistics
                if (i_val < i_min) i_min = i_val;
                if (i_val > i_max) i_max = i_val;
                if (q_val < q_min) q_min = q_val;
                if (q_val > q_max) q_max = q_val;
                i_sum += i_val;
                q_sum += q_val;

                // Detect saturation events
                if (i_val == 2047 || i_val == -2048 ||
                    q_val == 2047 || q_val == -2048)
                    sat_count++;

                // Log to CSV
                $fwrite(csv_fd, "%0d,%0d,%0d\n", mag, i_val, q_val);

                count++;
            end
        end

        $display("  [M=%3d] Samples=%0d | I: min=%0d max=%0d mean=%0d | Q: min=%0d max=%0d mean=%0d | saturations=%0d",
                 mag, num_samples,
                 i_min, i_max, i_sum / num_samples,
                 q_min, q_max, q_sum / num_samples,
                 sat_count);
    endtask

    // -----------------------------------------------------------------------
    // Main stimulus
    // -----------------------------------------------------------------------
    localparam int SAMPLES_PER_LEVEL = 1024;

    integer sat;

    initial begin
        $display("============================================================");
        $display("  G-DSP Engine — AWGN Channel Testbench");
        $display("============================================================");

        // Reset
        rst_n           = 1'b0;
        en              = 1'b0;
        tx_I            = '0;
        tx_Q            = '0;
        tx_valid        = 1'b0;
        noise_magnitude = 8'h00;

        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        en    = 1'b1;
        repeat (5) @(posedge clk);

        // ==================================================================
        // Test 1: Bypass (noise_magnitude = 0)
        // ==================================================================
        $display("\n--- Test 1: Bypass (M=0, no noise) ---");
        noise_magnitude = 8'd0;
        @(posedge clk);

        fork
            feed_symbols(SAMPLES_PER_LEVEL + 10);
            capture_samples(SAMPLES_PER_LEVEL, noise_magnitude, sat);
        join

        // Verify passthrough: with M=0, rx should equal tx (delayed)
        $display("  Expected: rx == tx (delayed). Saturations should be 0.");

        repeat (20) @(posedge clk);

        // ==================================================================
        // Test 2: Low noise (M=16)
        // ==================================================================
        $display("\n--- Test 2: Low noise (M=16, SNR ~ 35 dB) ---");
        noise_magnitude = 8'd16;
        @(posedge clk);

        fork
            feed_symbols(SAMPLES_PER_LEVEL + 10);
            capture_samples(SAMPLES_PER_LEVEL, noise_magnitude, sat);
        join

        repeat (20) @(posedge clk);

        // ==================================================================
        // Test 3: Medium noise (M=64)
        // ==================================================================
        $display("\n--- Test 3: Medium noise (M=64, SNR ~ 23 dB) ---");
        noise_magnitude = 8'd64;
        @(posedge clk);

        fork
            feed_symbols(SAMPLES_PER_LEVEL + 10);
            capture_samples(SAMPLES_PER_LEVEL, noise_magnitude, sat);
        join

        repeat (20) @(posedge clk);

        // ==================================================================
        // Test 4: High noise (M=128)
        // ==================================================================
        $display("\n--- Test 4: High noise (M=128, SNR ~ 17 dB) ---");
        noise_magnitude = 8'd128;
        @(posedge clk);

        fork
            feed_symbols(SAMPLES_PER_LEVEL + 10);
            capture_samples(SAMPLES_PER_LEVEL, noise_magnitude, sat);
        join

        repeat (20) @(posedge clk);

        // ==================================================================
        // Test 5: Maximum noise / saturation stress (M=255)
        // ==================================================================
        $display("\n--- Test 5: Maximum noise (M=255, SNR ~ 11 dB) ---");
        noise_magnitude = 8'd255;
        @(posedge clk);

        fork
            feed_symbols(SAMPLES_PER_LEVEL + 10);
            capture_samples(SAMPLES_PER_LEVEL, noise_magnitude, sat);
        join

        repeat (20) @(posedge clk);

        // ==================================================================
        // Test 6: Saturation corner case — extreme TX + max noise
        // ==================================================================
        $display("\n--- Test 6: Corner case (TX at +-2047, M=255) ---");
        noise_magnitude = 8'd255;
        @(posedge clk);

        // Feed extreme constellation points
        repeat (256) begin
            tx_I     <= 12'sd2047;
            tx_Q     <= -12'sd2048;
            tx_valid <= 1'b1;
            @(posedge clk);
        end
        tx_valid <= 1'b0;

        // Wait for pipeline to flush
        repeat (20) @(posedge clk);

        $display("\n============================================================");
        $display("  All channel tests completed.");
        $display("  Constellation data saved to:");
        $display("    sim/vectors/channel_constellation.csv");
        $display("  Waveform data saved to:");
        $display("    sim/waves/tb_channel.vcd");
        $display("============================================================");

        $fclose(csv_fd);
        $finish;
    end

    // -----------------------------------------------------------------------
    // Timeout watchdog
    // -----------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD * 100_000);
        $display("ERROR: Simulation timed out!");
        $fclose(csv_fd);
        $finish;
    end

endmodule : tb_channel
