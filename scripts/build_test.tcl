# Test LED Build Script
puts "========================================" 
puts "  Building test_led for Tang Nano 9K"
puts "========================================" 

# Configurar dispositivo
set_device GW1NR-LV9QN88PC6/I5

# Agregar archivos
add_file "../../rtl/top/test_led.sv"
add_file "../../gowin/gdsp_engine/src/gowin_rpll/gowin_rpll.v"

# Configurar top module
set_option -top_module test_led

# Constraints
add_file -type cst "../../constraints/test_led.cst"
set_option -verilog_std sysv2017

# Salida
set_option -output_base_name test_led

# Run
puts "--- Synthesis ---"
run syn

puts "--- Place & Route ---"
run pnr

puts "--- DONE ---"
if {[file exists "impl/test_led/test_led.fs"]} {
    set size [file size "impl/test_led/test_led.fs"]
    puts "Bitstream: impl/test_led/test_led.fs ([expr {$size / 1024.0}] KB)"
} else {
    puts "ERROR: Bitstream not generated"
}
