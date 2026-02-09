# scripts/flash_fpga.ps1
# G-DSP Engine — Build and Flash to Tang Nano 9K

param(
    [switch]$SkipBuild
)

# Configuración
$GOWIN_BIN = "C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe"
$PROGRAMMER = "C:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe"
$TCL_SCRIPT = "scripts\build.tcl"
$BITSTREAM = "gowin\gdsp_engine\impl\pnr\gdsp_engine.fs"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  G-DSP Engine - Build & Flash" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Paso 1: Build (opcional)
if (-not $SkipBuild) {
    Write-Host "`n[1/2] Compilando bitstream..." -ForegroundColor Yellow
    & $GOWIN_BIN $TCL_SCRIPT

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n[ERROR] Build fallo. Abortando." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "`n[1/2] Saltando build (usando bitstream existente)..." -ForegroundColor Yellow
}

# Verificar que existe el bitstream
if (-not (Test-Path $BITSTREAM)) {
    Write-Host "`n[ERROR] No se encuentra el bitstream: $BITSTREAM" -ForegroundColor Red
    exit 1
}

$fsFile = Get-Item $BITSTREAM
Write-Host "[OK] Bitstream generado: $($fsFile.Name) ($([math]::Round($fsFile.Length/1KB, 1)) KB)" -ForegroundColor Green

# Paso 2: Flash
Write-Host "`n[2/2] Programando Tang Nano 9K..." -ForegroundColor Yellow
Write-Host "Conecta la placa y espera..." -ForegroundColor Gray

# Comando para programar embFlash (operation_index 5 = embFlash)
$bitstreamPath = (Resolve-Path $BITSTREAM).Path
& $PROGRAMMER --device GW1NR-9C --operation_index 5 --fsFile "$bitstreamPath"

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  [EXITO] Bitstream cargado en Flash" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "La placa arrancara automaticamente.`nConecta HDMI para ver la constelacion." -ForegroundColor Gray
} else {
    Write-Host "`n[ERROR] Programacion fallida." -ForegroundColor Red
    Write-Host "Verifica que la placa este conectada." -ForegroundColor Yellow
}
