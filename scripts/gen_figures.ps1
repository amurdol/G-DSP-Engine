# ============================================================================
# G-DSP Engine - Generate All Documentation Figures
# ============================================================================
# Regenerates all PNG figures for TFG documentation.
# Output: docs/figures/*.png
# ============================================================================

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "========================================"
Write-Host "  G-DSP Engine - Figure Generation"
Write-Host "========================================"
Write-Host ""

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$FiguresDir = Join-Path $ProjectRoot "docs/figures"

# Ensure output directory exists
if (-not (Test-Path $FiguresDir)) {
    New-Item -ItemType Directory -Path $FiguresDir -Force | Out-Null
}

Push-Location $ProjectRoot

try {
    # 1. Ideal 16-QAM constellation reference
    Write-Host "[1/4] Generating 16-QAM ideal constellation..."
    python scripts/plot_constellation.py 2>&1 | Out-Null
    Write-Host "      -> constellation_16qam.png" -ForegroundColor Green

    # 2. TX/RX chain figures - golden model
    Write-Host "[2/4] Generating TX/RX chain figures..."
    python scripts/golden_model.py --nsym 256 --snr 20 2>&1 | Out-Null
    Write-Host "      -> constellation_tx.png" -ForegroundColor Green
    Write-Host "      -> constellation_rx.png" -ForegroundColor Green
    Write-Host "      -> spectrum_tx.png" -ForegroundColor Green
    Write-Host "      -> eye_diagram_I.png" -ForegroundColor Green
    Write-Host "      -> rrc_impulse.png" -ForegroundColor Green

    # 3. Costas loop debug figures
    Write-Host "[3/4] Generating Costas loop debug figures..."
    python scripts/debug_rx_chain.py 2>&1 | Out-Null
    Write-Host "      -> debug_01*.png - no impairments" -ForegroundColor Green
    Write-Host "      -> debug_02*.png - 45 deg phase" -ForegroundColor Green
    Write-Host "      -> debug_03*.png - 90 deg phase" -ForegroundColor Green

    # 4. RTL simulation constellation
    Write-Host "[4/4] Generating RTL simulation constellation..."
    & "$PSScriptRoot\run_constellation_sim.ps1" -RunRxTest 2>&1 | Out-Null
    Write-Host "      -> constellation_rx_sim.png" -ForegroundColor Green
}
finally {
    Pop-Location
}

# Summary
$figures = Get-ChildItem $FiguresDir -Filter "*.png" | Measure-Object
Write-Host ""
Write-Host "========================================"
Write-Host "  Done! Generated $($figures.Count) figures"
Write-Host "========================================"
Write-Host ""
Write-Host "Output directory: $FiguresDir"
Get-ChildItem $FiguresDir -Filter "*.png" -Name | ForEach-Object { Write-Host "  $_" }
Write-Host ""
