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

# 3. Ejecutar Síntesis
puts "--- Iniciando Sintesis (Synthesis) ---"
run syn

# 4. Ejecutar Place & Route (PnR) y Generar Bitstream
puts "--- Iniciando Place & Route y Bitstream ---"
run pnr

puts "--- PROCESO COMPLETADO EXITOSAMENTE ---"
exit 0
