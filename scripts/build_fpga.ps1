# scripts/build_fpga.ps1
# G-DSP Engine — Gowin FPGA Build Launcher

# Configuración de rutas
$GOWIN_BIN = "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe"
$TCL_SCRIPT = "scripts\build.tcl"

# Verificar que Gowin existe
if (-not (Test-Path $GOWIN_BIN)) {
    Write-Error "No se encuentra gw_sh.exe en: $GOWIN_BIN"
    Write-Host "Verifica la ruta de instalacion." -ForegroundColor Red
    exit 1
}

# Verificar que el script TCL existe
if (-not (Test-Path $TCL_SCRIPT)) {
    Write-Error "No se encuentra el script TCL en: $TCL_SCRIPT"
    exit 1
}

# Ejecutar el build
Write-Host "Iniciando compilacion de FPGA con Gowin..." -ForegroundColor Cyan
Write-Host "Ejecutando: $GOWIN_BIN $TCL_SCRIPT" -ForegroundColor Gray
& $GOWIN_BIN $TCL_SCRIPT

# Verificar resultado
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[EXITO] Bitstream generado." -ForegroundColor Green
    Write-Host "El archivo .fs esta en: gowin/gdsp_engine/impl/pnr/" -ForegroundColor Gray
    
    # Mostrar el archivo generado
    $fsFile = Get-ChildItem -Path "gowin/gdsp_engine/impl/pnr/*.fs" -ErrorAction SilentlyContinue
    if ($fsFile) {
        Write-Host "Bitstream: $($fsFile.Name) ($([math]::Round($fsFile.Length/1KB, 1)) KB)" -ForegroundColor Green
    }
} else {
    Write-Host "`n[ERROR] Algo fallo durante la compilacion." -ForegroundColor Red
    Write-Host "Revisa los logs en gowin/gdsp_engine/impl/" -ForegroundColor Yellow
}
