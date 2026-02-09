# ============================================================================
# G-DSP Engine — Timing Constraints (SDC)
# ============================================================================
# Target: Gowin GW1NR-LV9QN88PC6/I5 — Tang Nano 9K
# ============================================================================

# --- Primary clock: 27 MHz (37.037 ns period) ---
create_clock -name clk_27m -period 37.037 [get_ports {clk_27m}]

# --- Generated clocks ---
# Gowin rPLL and CLKDIV generate clocks automatically.
# The tool infers these from the primitives.
# clk_serial: 126 MHz (7.937 ns) — from Gowin_rPLL
# clk_pixel:  25.2 MHz (39.683 ns) — from Gowin_CLKDIV

# --- False paths ---
# Reset and button are asynchronous — exempt from timing
set_false_path -from [get_ports {rst_n}]
set_false_path -from [get_ports {btn_user}]

# --- Output delays (relaxed for HDMI) ---
# TMDS outputs have no external timing requirements
set_false_path -to [get_ports {tmds_*}]
set_false_path -to [get_ports {led[*]}]
