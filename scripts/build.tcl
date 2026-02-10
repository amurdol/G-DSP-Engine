# scripts/build.tcl
# G-DSP Engine — Gowin Build Script

# 1. Definir la ruta relativa al proyecto
set project_file "gowin/gdsp_engine/gdsp_engine.gprj"

# 2. Abrir el proyecto
if {[file exists $project_file]} {
    puts "--- Abriendo proyecto: $project_file ---"
    open_project $project_file
} else {
    puts "ERROR: No se encuentra el archivo de proyecto en $project_file"
    exit 1
}

# 3. Especificar top module explícitamente
set_option -top_module gdsp_top

# 4. Habilitar SystemVerilog 2017
set_option -verilog_std sysv2017

# 5. Agregar directorio de include para rrc_coeffs.v
set_option -include_path "C:/Users/aleja/Documents/Proyectos/G-DSP-Engine/sim/vectors"

# 6. Opciones de P&R para diseño de alta utilización
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1
set_option -timing_driven 1
set_option -place_option 1
set_option -route_option 1

# 7. Ejecutar Síntesis
puts "--- Iniciando Sintesis (Synthesis) ---"
run syn

# 4. Ejecutar Place & Route (PnR) y Generar Bitstream
puts "--- Iniciando Place & Route y Bitstream ---"
run pnr

puts "--- PROCESO COMPLETADO EXITOSAMENTE ---"
exit 0
