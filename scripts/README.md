# G-DSP Engine — Scripts

Quick reference for available scripts. Run from project root.

## PowerShell Scripts

| Script | Command | Description |
|--------|---------|-------------|
| **run_tests.ps1** | `.\scripts\run_tests.ps1` | Run ALL RTL testbenches (6 tests) |
| **build_fpga.ps1** | `.\scripts\build_fpga.ps1` | Synthesize RTL → bitstream |
| **flash_fpga.ps1** | `.\scripts\flash_fpga.ps1` | Build + Flash to Tang Nano 9K |
| | `.\scripts\flash_fpga.ps1 -SkipBuild` | Flash only (existing bitstream) |
| **run_constellation_sim.ps1** | `.\scripts\run_constellation_sim.ps1` | Simulate constellation renderer |

## Python Scripts

| Script | Command | Description |
|--------|---------|-------------|
| **golden_model.py** | `python scripts/golden_model.py --nsym 256 --snr 20` | Generate test vectors |
| **fixed_point.py** | `python scripts/fixed_point.py` | Fixed-point analysis |
| **debug_rx_chain.py** | `python scripts/debug_rx_chain.py` | Debug Costas Loop (floating-point) |

## Typical Workflow

```powershell
# 1. Run tests after RTL changes
.\scripts\run_tests.ps1

# 2. Build bitstream
.\scripts\build_fpga.ps1

# 3. Flash to FPGA
.\scripts\flash_fpga.ps1 -SkipBuild
```

## Output Locations

- **Bitstream:** `gowin/gdsp_engine/impl/pnr/gdsp_engine.fs`
- **VCD Waveforms:** `sim/waves/*.vcd`
- **Test Output:** `sim/out/*.vvp`
