# TCL script para compilar test_hdmi en Tang Nano 9K
# Gowin EDA - G-DSP Engine Test HDMI

# Proyecto
set_device -name GW1NR-9C GW1NR-LV9QN88PC6/I5

# RTL files - Test HDMI
add_file -type verilog "../../rtl/top/test_hdmi.sv"
add_file -type verilog "../../rtl/video/hdmi_tx.sv"

# IP cores
add_file -type verilog "../../gowin/gdsp_engine/src/gowin_rpll/gowin_rpll.v"
add_file -type verilog "../../gowin/gdsp_engine/src/gowin_clkdiv/gowin_clkdiv.v"

# Configurar top module
set_option -top_module test_hdmi

# Constraints
add_file -type cst "../../constraints/test_hdmi.cst"
set_option -verilog_std sysv2017

# Salida
set_option -output_base_name test_hdmi

# Ejecutar
run all
