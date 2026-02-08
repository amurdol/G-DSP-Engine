# ============================================================================
# G-DSP Engine — Timing Constraints (SDC)
# ============================================================================
# Target: Gowin GW1NR-LV9QN88PC6/I5 — Tang Nano 9K
# ============================================================================

# --- Primary clock: 27 MHz (37.037 ns period) ---
create_clock -name clk_27m -period 37.037 [get_ports {clk_27m}]

# --- Generated clocks (PLL outputs — Phase 4) ---
# create_clock -name clk_pix    -period 13.468 [get_pins {pll_inst/CLKOUT1}]
# create_clock -name clk_pix_5x -period 2.694  [get_pins {pll_inst/CLKOUT2}]

# --- False paths ---
# set_false_path -from [get_ports {rst_n}]

# --- Multicycle paths (timing closure) ---
