// ============================================================================
// G-DSP Engine — Timing Constraints (SDC)
// ============================================================================
// Target: Gowin GW1NR-LV9QN88PC6/I5 — Tang Nano 9K
// ============================================================================

// --- Primary clock ---
create_clock -name clk_27m -period 37.037 [get_ports clk_27m]
// 27 MHz → 37.037 ns

// --- Generated clocks (PLL outputs — update when PLL is instantiated) ---
// create_clock -name clk_sys    -period <TBD> [get_pins pll_inst/CLKOUT0]
// create_clock -name clk_pix    -period 13.468 [get_pins pll_inst/CLKOUT1]  // 74.25 MHz
// create_clock -name clk_pix_5x -period 2.694  [get_pins pll_inst/CLKOUT2]  // 371.25 MHz

// --- False paths ---
// Reset synchronizer
// set_false_path -from [get_ports rst_n]

// --- Multicycle paths (will be added during timing closure) ---
