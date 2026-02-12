# G-DSP Engine — Copilot Context Instructions

## Project Overview
G-DSP Engine is a 16-QAM modem implemented in SystemVerilog for the **Tang Nano 9K** (Gowin GW1NR-9C) FPGA. It displays a real-time constellation diagram via HDMI output.

## Available Scripts (USE THESE!)

### 1. Build FPGA Bitstream
```powershell
.\scripts\build_fpga.ps1
```
- Synthesizes RTL with Gowin toolchain
- Output: `gowin/gdsp_engine/impl/pnr/gdsp_engine.fs`
- Uses: `scripts/build.tcl` internally

### 2. Flash to FPGA
```powershell
.\scripts\flash_fpga.ps1           # Build + Flash
.\scripts\flash_fpga.ps1 -SkipBuild  # Flash only (use existing bitstream)
```
- Programs Tang Nano 9K via USB
- Writes to embedded flash (persistent)

### 3. Run RTL Testbenches
```powershell
.\scripts\run_tests.ps1
```
- Runs ALL testbenches (6 tests):
  - QAM Mapper, RRC Filter, TX Top, Channel, RX Top, GDSP Top
- Uses Icarus Verilog (iverilog/vvp)
- Output: `sim/waves/*.vcd`, `sim/out/*.vvp`

### 4. Run Constellation Simulation
```powershell
.\scripts\run_constellation_sim.ps1
.\scripts\run_constellation_sim.ps1 -SkipSim  # Visualization only
```
- Simulates constellation renderer
- Generates visual output

## Python Scripts

### Golden Model
```powershell
python scripts/golden_model.py --nsym 256 --snr 20
```
- Generates test vectors for RTL verification

### Fixed-Point Analysis
```powershell
python scripts/fixed_point.py
```
- Analyzes fixed-point precision

### Debug RX Chain (NEW)
```powershell
python scripts/debug_rx_chain.py
```
- Floating-point simulation of TX→Channel→RX
- Useful for debugging Costas Loop behavior

## Project Structure

```
rtl/
├── packages/gdsp_pkg.sv     # Global types and parameters
├── modem/
│   ├── qam16_mapper.sv      # 16-QAM symbol mapper
│   ├── rrc_filter.sv        # 5-tap RRC pulse shaping
│   └── tx_top.sv            # TX subsystem
├── channel/
│   ├── awgn_channel.sv      # AWGN channel model
│   └── awgn_generator.sv    # Noise generator
├── sync/
│   ├── costas_loop.sv       # Carrier recovery (DD-PLL)
│   └── gardner_ted.sv       # Timing error detector
├── video/
│   ├── constellation_renderer.sv
│   └── hdmi_tx.sv
└── top/gdsp_top.sv          # Top-level integration

sim/
├── tb/                      # Testbenches
├── vectors/                 # Test vectors (.mem, .csv)
└── waves/                   # VCD waveforms

gowin/gdsp_engine/           # Gowin IDE project
├── impl/pnr/gdsp_engine.fs  # Output bitstream
└── gdsp_engine.gprj         # Project file

constraints/
├── tangnano9k.cst           # Pin constraints
└── timing.sdc               # Timing constraints
```

## Key Technical Parameters

| Parameter | Value |
|-----------|-------|
| FPGA | Gowin GW1NR-9C (Tang Nano 9K) |
| Clock | 27 MHz |
| Sample Rate | 27 MSPS |
| Symbol Rate | 6.75 Msym/s (SPS=4) |
| Modulation | 16-QAM (Gray coded) |
| RRC Filter | 5 taps, α=0.25 |
| Data Width | 12-bit signed (Q1.11) |
| Video | 480p60 HDMI via DVI |

## Resource Usage (Current)
- **Logic:** 77% (6635/8640)
- **Register:** 35% (2321/6693)
- **DSP:** 100% (10/10)
- **BSRAM:** 0%

## Common Workflow

1. **Make RTL changes** → Edit `.sv` files
2. **Run tests** → `.\scripts\run_tests.ps1`
3. **Build** → `.\scripts\build_fpga.ps1`
4. **Flash** → `.\scripts\flash_fpga.ps1 -SkipBuild`

## Debugging Tips

- **Two circles on HDMI** = Costas Loop not locking (check rotator polarity)
- **Saturated signal** = Gain/scaling issue in fixed-point
- **Lock never asserts** = Loop gains too weak or dead zone too large
- **ISI visible** = 5-tap RRC limitation (~20% expected)

## Important Notes

- Always run `.\scripts\run_tests.ps1` before building
- The Costas Loop uses **conjugate rotation** to remove channel phase
- 16-QAM has 90° phase ambiguity (any multiple of 90° is valid lock)
