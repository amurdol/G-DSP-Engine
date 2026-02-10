# ============================================================================
# G-DSP Engine — Run Constellation Renderer Simulation
# ============================================================================
# Script to compile and run tb_constellation_renderer testbench
# and then visualize the results
# ============================================================================

param(
    [switch]$SkipSim,      # Skip simulation, only run visualization
    [switch]$NoViz,        # Skip visualization
    [string]$Simulator = "iverilog"  # Simulator: iverilog, verilator
)

$ErrorActionPreference = "Stop"

# Paths
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SimDir = Join-Path $ProjectRoot "sim"
$TbDir = Join-Path $SimDir "tb"
$RtlDir = Join-Path $ProjectRoot "rtl"
$OutDir = Join-Path $SimDir "output"
$ScriptsDir = Join-Path $ProjectRoot "scripts"

# Create output directory
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

Write-Host "========================================"
Write-Host "  Constellation Renderer Simulation"
Write-Host "========================================"
Write-Host ""

# ============================================================================
# Step 1: Compile and Run Simulation
# ============================================================================
if (-not $SkipSim) {
    Write-Host "[1/3] Compiling testbench..."
    
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
    
    # Change to sim directory for output files
    Push-Location $SimDir
    
    try {
        if ($Simulator -eq "iverilog") {
            # Compile with Icarus Verilog
            $CompileCmd = "iverilog -g2012 -o tb_constellation_renderer.vvp " + 
                          ($SourceFiles -join " ")
            
            Write-Host "  Command: $CompileCmd"
            Invoke-Expression $CompileCmd
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] Compilation failed!" -ForegroundColor Red
                Pop-Location
                exit 1
            }
            
            Write-Host "[OK] Compilation successful." -ForegroundColor Green
            Write-Host ""
            
            # Run simulation
            Write-Host "[2/3] Running simulation (this may take a few minutes)..."
            Write-Host "      Simulating one complete VGA frame (640x480 = 307,200 pixels)"
            Write-Host ""
            
            $RunCmd = "vvp tb_constellation_renderer.vvp"
            Write-Host "  Command: $RunCmd"
            Invoke-Expression $RunCmd
            
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] Simulation failed!" -ForegroundColor Red
                Pop-Location
                exit 1
            }
        }
        elseif ($Simulator -eq "verilator") {
            Write-Host "[INFO] Verilator support not yet implemented"
            Write-Host "       Use: -Simulator iverilog"
            Pop-Location
            exit 1
        }
        else {
            Write-Host "[ERROR] Unknown simulator: $Simulator" -ForegroundColor Red
            Pop-Location
            exit 1
        }
        
        # Check if CSV was generated
        $CsvPath = Join-Path $SimDir "constellation_frame.csv"
        if (Test-Path $CsvPath) {
            $FileInfo = Get-Item $CsvPath
            Write-Host ""
            Write-Host "[OK] CSV file generated: constellation_frame.csv" -ForegroundColor Green
            Write-Host "     Size: $([math]::Round($FileInfo.Length / 1MB, 2)) MB"
            
            # Move to output directory
            $DestCsv = Join-Path $OutDir "constellation_frame.csv"
            Move-Item -Path $CsvPath -Destination $DestCsv -Force
            Write-Host "     Moved to: $DestCsv"
        }
        else {
            Write-Host "[WARNING] CSV file was not generated!" -ForegroundColor Yellow
        }
        
        # Move VCD if generated
        $VcdPath = Join-Path $SimDir "tb_constellation_renderer.vcd"
        if (Test-Path $VcdPath) {
            $DestVcd = Join-Path $OutDir "tb_constellation_renderer.vcd"
            Move-Item -Path $VcdPath -Destination $DestVcd -Force
            Write-Host "     Waveform saved to: $DestVcd"
        }
        
    }
    finally {
        Pop-Location
    }
    
    Write-Host ""
    Write-Host "[OK] Simulation complete!" -ForegroundColor Green
}
else {
    Write-Host "[INFO] Skipping simulation (-SkipSim)"
}

# ============================================================================
# Step 2: Visualize Results
# ============================================================================
if (-not $NoViz) {
    Write-Host ""
    Write-Host "[3/3] Running visualization script..."
    
    $CsvPath = Join-Path $OutDir "constellation_frame.csv"
    
    if (-not (Test-Path $CsvPath)) {
        Write-Host "[ERROR] CSV file not found: $CsvPath" -ForegroundColor Red
        Write-Host "        Run simulation first or provide the CSV file."
        exit 1
    }
    
    $PythonScript = Join-Path $ScriptsDir "visualize_constellation.py"
    
    if (-not (Test-Path $PythonScript)) {
        Write-Host "[ERROR] Python script not found: $PythonScript" -ForegroundColor Red
        exit 1
    }
    
    # Run Python visualization
    Push-Location $ProjectRoot
    try {
        python $PythonScript $CsvPath
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host "[INFO] Skipping visualization (-NoViz)"
}

Write-Host ""
Write-Host "========================================"
Write-Host "  Process Complete!"
Write-Host "========================================"
Write-Host ""
Write-Host "Output files in: $OutDir"
Write-Host "  - constellation_frame.csv (pixel data)"
Write-Host "  - constellation_640x480.png (original)"
Write-Host "  - constellation_1920x1080.png (scaled)"
Write-Host "  - constellation_comparison.png (side by side)"
Write-Host "  - tb_constellation_renderer.vcd (waveforms)"
Write-Host ""
