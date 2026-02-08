# ==============================================================================
# G-DSP Engine — Run All Testbenches
# ==============================================================================
# Usage:  powershell -ExecutionPolicy Bypass -File scripts/run_tests.ps1
#         or from the project root:  .\scripts\run_tests.ps1
#
# Prerequisites:
#   - Icarus Verilog (iverilog, vvp) in PATH
#     Install via MSYS2:  pacman -S mingw-w64-x86_64-iverilog
#     Ensure C:\msys64\mingw64\bin is in PATH
#   - Golden Model vectors generated:
#     python scripts/golden_model.py --nsym 256 --snr 20
# ==============================================================================

$ErrorActionPreference = "Continue"

# Ensure we're at the project root
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $ProjectRoot

# Ensure C:\msys64\mingw64\bin is in PATH for this session
if ($env:PATH -notmatch "msys64\\mingw64\\bin") {
    $env:PATH = "C:\msys64\mingw64\bin;$env:PATH"
}

# Verify tools
try {
    $null = Get-Command iverilog -ErrorAction Stop
    $null = Get-Command vvp -ErrorAction Stop
} catch {
    Write-Error "iverilog/vvp not found in PATH. Install via: pacman -S mingw-w64-x86_64-iverilog"
    exit 1
}

# Create output directories
New-Item -ItemType Directory -Force -Path sim/waves | Out-Null
New-Item -ItemType Directory -Force -Path sim/out   | Out-Null

# ==============================================================================
# Test definitions: [Name, OutputVVP, SourceFiles[]]
# ==============================================================================
$IVERILOG_FLAGS = @("-g2012", "-I", "sim/vectors")

$tests = @(
    @{
        Name    = "QAM Mapper (truth table)"
        VVP     = "sim/out/tb_qam16_mapper.vvp"
        Sources = @(
            "rtl/packages/gdsp_pkg.sv",
            "rtl/modem/qam16_mapper.sv",
            "sim/tb/tb_qam16_mapper.sv"
        )
    },
    @{
        Name    = "RRC Filter (impulse + vector)"
        VVP     = "sim/out/tb_rrc_filter.vvp"
        Sources = @(
            "rtl/packages/gdsp_pkg.sv",
            "rtl/modem/rrc_filter.sv",
            "sim/tb/tb_rrc_filter.sv"
        )
    },
    @{
        Name    = "TX Top (integration)"
        VVP     = "sim/out/tb_tx_top.vvp"
        Sources = @(
            "rtl/packages/gdsp_pkg.sv",
            "rtl/common/bit_gen.sv",
            "rtl/modem/qam16_mapper.sv",
            "rtl/modem/rrc_filter.sv",
            "rtl/modem/tx_top.sv",
            "sim/tb/tb_tx_top.sv"
        )
    },
    @{
        Name    = "AWGN Channel (noise sweep)"
        VVP     = "sim/out/tb_channel.vvp"
        Sources = @(
            "rtl/packages/gdsp_pkg.sv",
            "rtl/channel/awgn_generator.sv",
            "rtl/channel/awgn_channel.sv",
            "sim/tb/tb_channel.sv"
        )
    },
    @{
        Name    = "RX Top (full modem chain)"
        VVP     = "sim/out/tb_rx_top.vvp"
        Sources = @(
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
        )
    },
    @{
        Name    = "GDSP Top (Phase 4 integration)"
        VVP     = "sim/out/tb_gdsp_top.vvp"
        Flags   = @("-g2012", "-DSIMULATION", "-I", "sim/vectors")
        Sources = @(
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
            "rtl/video/constellation_renderer.sv",
            "rtl/video/hdmi_tx.sv",
            "rtl/top/gdsp_top.sv",
            "sim/tb/tb_gdsp_top.sv"
        )
    }
)

# ==============================================================================
# Run all tests
# ==============================================================================
$pass  = 0
$fail  = 0
$total = $tests.Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  G-DSP Engine - Testbench Suite (${total} tests)"          -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($t in $tests) {
    $name = $t.Name
    Write-Host "--- [$name] ---" -ForegroundColor Yellow

    # Compile (use custom flags if defined, else default)
    Write-Host "  Compiling..." -NoNewline
    $flags = if ($t.Flags) { $t.Flags } else { $IVERILOG_FLAGS }
    $compileArgs = $flags + @("-o", $t.VVP) + $t.Sources
    & iverilog @compileArgs 2>&1 | Out-Null

    if (-not (Test-Path $t.VVP)) {
        Write-Host " COMPILE FAILED" -ForegroundColor Red
        $fail++
        continue
    }
    Write-Host " OK" -ForegroundColor Green

    # Simulate
    Write-Host "  Simulating..." -NoNewline
    $simOutput = & vvp $t.VVP 2>&1 | Out-String

    # Check for PASS/FAIL in output
    if ($simOutput -match "ALL.*PASSED|Simulation Complete|All channel tests completed|Stress Test Passed") {
        Write-Host " PASS" -ForegroundColor Green
        $pass++
    } else {
        Write-Host " FAIL (check output)" -ForegroundColor Red
        $fail++
    }

    # Print condensed output (skip VCD info lines)
    $simOutput -split "`n" | Where-Object {
        $_ -notmatch "^VCD info" -and $_ -match "\S"
    } | ForEach-Object { Write-Host "    $_" }

    Write-Host ""
}

# ==============================================================================
# Summary
# ==============================================================================
Write-Host "============================================================" -ForegroundColor Cyan
if ($fail -eq 0) {
    Write-Host "  RESULT: ALL ${pass}/${total} TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "  RESULT: ${pass} PASSED, ${fail} FAILED (of ${total})" -ForegroundColor Red
}
Write-Host "============================================================" -ForegroundColor Cyan

exit $fail
