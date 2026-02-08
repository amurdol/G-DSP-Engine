# ============================================================================
# G-DSP Engine — Timing Constraints (SDC)
# ============================================================================
# Target: Gowin GW1NR-LV9QN88PC6/I5 — Tang Nano 9K
# ============================================================================

# --- Primary clock: 27 MHz (37.037 ns period) ---
create_clock -name clk_27m -period 37.037 [get_ports {clk_27m}]

# --- Generated clocks (PLL outputs) ---
# clk_dsp:    27 MHz passthrough (same as input, no constraint needed if PLL)
# clk_pixel:  74.25 MHz (13.468 ns period) — 720p60 pixel clock
# clk_serial: 371.25 MHz (2.694 ns period) — TMDS 5× serialisation clock
create_clock -name clk_pixel  -period 13.468 [get_pins {u_pll/clkout1}]
create_clock -name clk_serial -period 2.694  [get_pins {u_pll/clkout2}]

# --- Clock groups ---
# clk_27m and clk_pixel are asynchronous (PLL-generated, different phase)
set_clock_groups -asynchronous -group {clk_27m} -group {clk_pixel clk_serial}

# --- False paths ---
# Reset is asynchronous — exempt from timing
set_false_path -from [get_ports {rst_n}]
set_false_path -from [get_ports {btn_user}]

# --- CDC paths (clk_dsp → clk_pixel) ---
# The constellation_renderer has a 2-FF synchroniser for sym_valid.
# Set max_delay or false_path to prevent over-constraining.
set_false_path -from [get_clocks clk_27m] -to [get_clocks clk_pixel]

# --- Multicycle paths (timing closure) ---
# None required at this stage; add if synthesis reports violations.
