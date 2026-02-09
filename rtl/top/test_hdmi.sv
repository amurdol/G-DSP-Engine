// Test HDMI - Pantalla roja sólida para verificar arquitectura HDMI
module test_hdmi (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led,
    output logic       tmds_clk_p,
    output logic       tmds_clk_n,
    output logic [2:0] tmds_data_p,
    output logic [2:0] tmds_data_n
);

    logic clk_pixel, clk_serial, pll_lock;
    
    // PLL: 27 MHz → 112.5 MHz
    Gowin_rPLL u_pll (
        .clkin(clk_27m),
        .clkout(clk_serial),
        .lock(pll_lock)
    );
    
    // CLKDIV: 112.5 MHz / 4.5 → 25 MHz
    Gowin_CLKDIV u_clkdiv (
        .hclkin(clk_serial),
        .resetn(pll_lock),
        .clkout(clk_pixel)
    );
    
    wire sys_rst = rst_n && pll_lock;
    
    // VGA timing generator (640x480@60Hz)
    logic [9:0] h_cnt, v_cnt;
    logic hsync, vsync, video_active;
    
    always_ff @(posedge clk_pixel or negedge sys_rst) begin
        if (!sys_rst) begin
            h_cnt <= 0;
            v_cnt <= 0;
        end else begin
            if (h_cnt == 799) begin
                h_cnt <= 0;
                if (v_cnt == 524)
                    v_cnt <= 0;
                else
                    v_cnt <= v_cnt + 1;
            end else
                h_cnt <= h_cnt + 1;
        end
    end
    
    assign hsync = ~((h_cnt >= 656) && (h_cnt < 752));  // Active-low
    assign vsync = ~((v_cnt >= 490) && (v_cnt < 492));  // Active-low
    assign video_active = (h_cnt < 640) && (v_cnt < 480);
    
    // RGB: Rojo sólido durante video activo
    logic [7:0] red, green, blue;
    assign red   = video_active ? 8'hFF : 8'h00;
    assign green = video_active ? 8'h00 : 8'h00;
    assign blue  = video_active ? 8'h00 : 8'h00;
    
    // HDMI TX con TLVDS_OBUF
    hdmi_tx u_hdmi (
        .clk_pixel(clk_pixel),
        .clk_serial(clk_serial),
        .rst_n(sys_rst),
        .rgb({red, green, blue}),
        .hsync(hsync),
        .vsync(vsync),
        .de(video_active),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_data_p),
        .tmds_d_n(tmds_data_n)
    );
    
    // LEDs de diagnóstico
    logic [26:0] cnt;
    always_ff @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) cnt <= 0;
        else cnt <= cnt + 1;
    end
    
    assign led[0] = ~cnt[24];      // Heartbeat
    assign led[1] = ~pll_lock;     // PLL lock
    assign led[2] = ~sys_rst;      // System running
    assign led[3] = ~hsync;        // Hsync activity
    assign led[4] = ~vsync;        // Vsync activity
    assign led[5] = ~video_active; // Video active

endmodule
