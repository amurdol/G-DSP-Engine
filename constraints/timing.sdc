# ============================================================================
# G-DSP Engine — Timing Constraints (SDC)
# ============================================================================
# Target: Gowin GW1NR-LV9QN88PC6/I5 — Tang Nano 9K
# ============================================================================

# --- Primary clock: 27 MHz (37.037 ns period) ---
create_clock -name clk_27m -period 37.037 [get_ports {clk_27m}]

# --- Generated clocks ---
# clk_dsp:    27 MHz (same as clk_27m, directly connected)
# clk_serial: 371.25 MHz (2.694 ns) — from Gowin_rPLL
# clk_pixel:  74.25 MHz (13.468 ns) — from Gowin_CLKDIV (clk_serial / 5)
create_clock -name clk_serial -period 2.694  [get_pins {u_pll/clkout}]
create_clock -name clk_pixel  -period 13.468 [get_pins {u_clkdiv/clkout}]

# --- Clock groups ---
# clk_27m (clk_dsp) and clk_pixel/clk_serial are asynchronous
set_clock_groups -asynchronous -group {clk_27m} -group {clk_pixel clk_serial}

# --- False paths ---
# Reset and button are asynchronous — exempt from timing
set_false_path -from [get_ports {rst_n}]
set_false_path -from [get_ports {btn_user}]

# --- CDC paths (clk_dsp → clk_pixel) ---
# The constellation_renderer has a 2-FF synchroniser for sym_valid.
# Set false_path to prevent over-constraining.
set_false_path -from [get_clocks clk_27m] -to [get_clocks clk_pixel]

# --- Multicycle paths (timing closure) ---
# None required at this stage; add if synthesis reports violations.
