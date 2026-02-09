// ============================================================================
// Test LED - Verificación básica de funcionamiento
// ============================================================================
// Diseño mínimo para verificar que:
// 1. El PLL funciona
// 2. Los LEDs responden
// 3. El reset funciona
// ============================================================================

module test_led (
    input  logic       clk_27m,
    input  logic       rst_n,
    output logic [5:0] led
);

    // PLL: 27 MHz → 126 MHz
    logic clk_serial, pll_lock;
    
    Gowin_rPLL u_pll (
        .clkin  (clk_27m),
        .clkout (clk_serial),
        .lock   (pll_lock)
    );

    // Contador para heartbeat
    logic [26:0] counter;
    
    always_ff @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n)
            counter <= '0;
        else
            counter <= counter + 1'b1;
    end

    // LEDs (active-low):
    // LED[0]: Heartbeat rápido (bit 23 ~ 3.2 Hz)
    // LED[1]: Heartbeat lento (bit 25 ~ 0.8 Hz)
    // LED[2]: PLL lock
    // LED[3]: Reset activo (debe estar apagado en operación normal)
    // LED[4]: Siempre encendido
    // LED[5]: Siempre apagado
    
    assign led[0] = ~counter[23];
    assign led[1] = ~counter[25];
    assign led[2] = ~pll_lock;
    assign led[3] = rst_n;         // ON cuando reset (invertido por active-low)
    assign led[4] = 1'b0;          // Siempre encendido (active-low)
    assign led[5] = 1'b1;          // Siempre apagado

endmodule
