# ============================================================================
# G-DSP Engine — Constellation Simulation & Visualization
# ============================================================================
# Two modes:
#   1. Quick plot: Plot RX constellation from tb_rx_top output (default)
#   2. Renderer sim: Full renderer testbench simulation
#
# Usage:
#   .\scripts\run_constellation_sim.ps1              # Quick plot (RX data)
#   .\scripts\run_constellation_sim.ps1 -RunRxTest   # Run RX test first, then plot
#   .\scripts\run_constellation_sim.ps1 -SimRenderer # Full renderer simulation
# ============================================================================

param(
    [switch]$RunRxTest,    # Run tb_rx_top first to generate fresh data
    [switch]$SimRenderer,  # Run full renderer testbench (slow)
    [switch]$NoPlot,       # Skip Python visualization
    [switch]$Show          # Show interactive plot window
)

$ErrorActionPreference = "Continue"

# Paths
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SimDir = Join-Path $ProjectRoot "sim"
$TbDir = Join-Path $SimDir "tb"
$RtlDir = Join-Path $ProjectRoot "rtl"
$OutDir = Join-Path $SimDir "out"
$WavesDir = Join-Path $SimDir "waves"
$VectorsDir = Join-Path $SimDir "vectors"
$FiguresDir = Join-Path $ProjectRoot "docs/figures"
$ScriptsDir = Join-Path $ProjectRoot "scripts"

# Ensure output directories exist
@($OutDir, $WavesDir, $FiguresDir) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "  G-DSP Constellation Visualization"
Write-Host "========================================"
Write-Host ""

# ============================================================================
# Mode 1: Quick RX Constellation Plot (default)
# ============================================================================
if (-not $SimRenderer) {
    # Optionally run RX test first
    if ($RunRxTest) {
        Write-Host "[1/2] Running RX Top testbench to generate constellation data..."
        Write-Host ""
        
        Push-Location $ProjectRoot
        try {
            # Source files for RX test
            $RxSources = @(
                "rtl/packages/gdsp_pkg.sv",
                "rtl/common/bit_gen.sv",
                "rtl/modem/qam16_mapper.sv",
                "rtl/modem/rrc_filter.sv",
                "rtl/modem/tx_top.sv",
                "rtl/channel/awgn_generator.sv",
                "rtl/channel/awgn_channel.sv",
                "rtl/sync/gardner_ted.sv",
                "rtl/sync/costas_loop.sv",
                "rtl/modem/rx_top.sv",
                "sim/tb/tb_rx_top.sv"
            ) -join " "
            
            $VvpPath = "sim/out/tb_rx_top.vvp"
            
            # Compile
            $CompileCmd = "iverilog -g2012 -I sim/vectors -o $VvpPath $RxSources"
            Write-Host "  Compiling..."
            Invoke-Expression $CompileCmd 2>&1 | Out-Null
            
            if (-not (Test-Path $VvpPath)) {
                Write-Host "[ERROR] Compilation failed!" -ForegroundColor Red
                Pop-Location
                exit 1
            }
            
            # Run
            Write-Host "  Simulating (this takes ~30 seconds)..."
            $RunCmd = "vvp $VvpPath"
            Invoke-Expression $RunCmd 2>&1 | Out-Null
            
            Write-Host "[OK] RX test complete." -ForegroundColor Green
        }
        finally {
            Pop-Location
        }
        Write-Host ""
    }
    
    # Check CSV exists
    $CsvPath = Join-Path $VectorsDir "rx_constellation.csv"
    if (-not (Test-Path $CsvPath)) {
        Write-Host "[ERROR] RX constellation CSV not found: $CsvPath" -ForegroundColor Red
        Write-Host "        Run with -RunRxTest or execute: .\scripts\run_tests.ps1"
        exit 1
    }
    
    # Plot
    if (-not $NoPlot) {
        $Step = if ($RunRxTest) { "[2/2]" } else { "[1/1]" }
        Write-Host "$Step Plotting RX constellation..."
        
        $PlotScript = Join-Path $ScriptsDir "plot_rx_constellation.py"
        $PlotArgs = "--csv `"$CsvPath`""
        if ($Show) { $PlotArgs += " --show" }
        
        Push-Location $ProjectRoot
        try {
            Invoke-Expression "python `"$PlotScript`" $PlotArgs"
        }
        finally {
            Pop-Location
        }
    }
    
    Write-Host ""
    Write-Host "========================================"
    Write-Host "  Done!"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "Output: docs/figures/constellation_rx_sim.png"
    Write-Host ""
    exit 0
}

# ============================================================================
# Mode 2: Full Renderer Simulation (slow, for testing renderer module)
# ============================================================================
Write-Host "[INFO] Running full renderer simulation..."
Write-Host "       This simulates the constellation_renderer module itself."
Write-Host "       For quick RX constellation plots, omit -SimRenderer."
Write-Host ""

# Source files
$SourceFiles = @(
    (Join-Path $RtlDir "packages/gdsp_pkg.sv"),
    (Join-Path $RtlDir "video/constellation_renderer.sv"),
    (Join-Path $TbDir "tb_constellation_renderer.sv")
)

# Check all files exist
foreach ($file in $SourceFiles) {
    if (-not (Test-Path $file)) {
        Write-Host "[ERROR] File not found: $file" -ForegroundColor Red
        exit 1
    }
}

Write-Host "[1/3] Compiling testbench..."

$VvpPath = Join-Path $OutDir "tb_constellation_renderer.vvp"
$CompileCmd = "iverilog -g2012 -o `"$VvpPath`" " + ($SourceFiles -join " ")

Write-Host "  $CompileCmd"
Invoke-Expression $CompileCmd

if (-not (Test-Path $VvpPath)) {
    Write-Host "[ERROR] Compilation failed!" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Compilation successful." -ForegroundColor Green
Write-Host ""

# Run simulation
Write-Host "[2/3] Running simulation (this may take a few minutes)..."
Write-Host "      Simulating one complete VGA frame (640x480 = 307,200 pixels)"
Write-Host ""

# Run from project root so relative paths in testbench work correctly
Push-Location $ProjectRoot
try {
    $RunCmd = "vvp `"$VvpPath`""
    Write-Host "  $RunCmd"
    Invoke-Expression $RunCmd
    
    # Check outputs in their expected locations
    $CsvPath = Join-Path $VectorsDir "constellation_frame.csv"
    $VcdPath = Join-Path $WavesDir "tb_constellation_renderer.vcd"
    
    if (Test-Path $CsvPath) {
        $FileInfo = Get-Item $CsvPath
        Write-Host "[OK] CSV saved: $CsvPath ($([math]::Round($FileInfo.Length / 1MB, 2)) MB)" -ForegroundColor Green
    }
    else {
        Write-Host "[WARN] CSV not generated" -ForegroundColor Yellow
    }
    
    if (Test-Path $VcdPath) {
        Write-Host "[OK] VCD saved: $VcdPath" -ForegroundColor Green
    }
}
finally {
    Pop-Location
}

Write-Host ""

# Visualize
if (-not $NoPlot) {
    Write-Host "[3/3] Running visualization..."
    
    $CsvPath = Join-Path $VectorsDir "constellation_frame.csv"
    $PythonScript = Join-Path $ScriptsDir "visualize_constellation.py"
    
    if (Test-Path $CsvPath) {
        Push-Location $ProjectRoot
        try {
            python $PythonScript $CsvPath
        }
        finally {
            Pop-Location
        }
    }
    else {
        Write-Host "[WARN] CSV not found, skipping visualization." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host "  Renderer Simulation Complete!"
Write-Host "========================================"
Write-Host ""
Write-Host "Output files:"
Write-Host "  sim/out/tb_constellation_renderer.vvp"
Write-Host "  sim/waves/tb_constellation_renderer.vcd"
Write-Host "  sim/vectors/constellation_frame.csv"
Write-Host "  docs/figures/constellation_*.png"
Write-Host ""
