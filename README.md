# G-DSP Engine

> **16-QAM Baseband Processor with Real-Time HDMI Visualisation**  
> Final Degree Project (TFG) — FPGA-based DSP on Gowin GW1NR-9

---

## Project Summary

G-DSP Engine is a **fully hardware-implemented 16-QAM digital modem**
running on the **Sipeed Tang Nano 9K** (Gowin GW1NR-LV9QN88PC6/I5).
The system performs complete transmit/receive signal processing including:

- **Modulation**: Gray-coded 16-QAM symbol mapping
- **Pulse Shaping**: Root-raised cosine (RRC) FIR filter, α=0.25, 33 taps
- **Channel Model**: Parametric AWGN noise injection (CLT-based)
- **Timing Recovery**: Gardner TED with NCO-based interpolation
- **Carrier Recovery**: Decision-directed Costas loop with dual gear-shifting
- **Visualisation**: Real-time IQ constellation on **720p @ 60 Hz HDMI**

No soft-core CPU is used in the data path — all DSP runs purely in RTL.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              G-DSP Engine                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐    │
│  │  PRBS   │──>│ 16-QAM   │──>│  RRC Tx  │──>│   AWGN   │──>│  RRC Rx  │    │
│  │ Bit Gen │   │ Mapper   │   │  Filter  │   │ Channel  │   │ Matched  │    │
│  └─────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘    │
│    Phase 1        Phase 1        Phase 1        Phase 2        Phase 3      │
│                                                                       │     │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐             │     │
│  │  HDMI   │<──│ Constel. │<──│  Costas  │<──│ Gardner  │<────────────┘     │
│  │ 720p60  │   │ Renderer │   │   Loop   │   │   TED    │                   │
│  └─────────┘   └──────────┘   └──────────┘   └──────────┘                   │
│    Phase 4        Phase 4        Phase 3        Phase 3                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Hardware Platform

| Parameter       | Value                                    |
|-----------------|------------------------------------------|
| **FPGA**        | Gowin GW1NR-LV9QN88PC6/I5               |
| **LUTs**        | 8,640                                    |
| **DSP Slices**  | 20 (MULT9×pREG)                         |
| **BSRAM**       | 26 × 18 Kbit                             |
| **PSRAM**       | 64 Mbit HyperRAM (available, not used)   |
| **Video Out**   | HDMI 720p @ 60 Hz (TMDS)                 |
| **Clock**       | 27 MHz → PLL → 27/74.25/371.25 MHz      |

---

## Fixed-Point Format

**Q1.11** — 12-bit signed, two's complement.

| Property    | Value                              |
|-------------|------------------------------------|
| Range       | $[-1.0, +1.0 - 2^{-11}]$          |
| Resolution  | $2^{-11} \approx 4.88 \times 10^{-4}$ |
| SQNR        | ~68 dB                             |

See [Fase 0 Documentation](docs/tex/fase0_analysis.tex) for rigorous derivation
and [fixed\_point\_analysis.md](docs/fixed_point_analysis.md) for design notes.

---

## Repository Structure

```
G-DSP-Engine/
├── rtl/                        # Synthesisable RTL (SystemVerilog)
│   ├── packages/gdsp_pkg.sv    #   Global parameters & types
│   ├── common/bit_gen.sv       #   PRBS-23 generator
│   ├── modem/                  #   QAM mapper, RRC filters, TX/RX tops
│   ├── channel/                #   AWGN noise generator & channel
│   ├── sync/                   #   Gardner TED, Costas loop
│   ├── video/                  #   Constellation renderer, HDMI TX
│   └── top/gdsp_top.sv         #   System top-level
│
├── sim/                        # Simulation & verification
│   ├── tb/                     #   SystemVerilog testbenches
│   ├── vectors/                #   Stimulus from golden model (.hex/.mem)
│   ├── out/                    #   Compiled VVP binaries (git-ignored)
│   └── waves/                  #   VCD waveform dumps (git-ignored)
│
├── scripts/                    # Automation & golden model
│   ├── golden_model.py         #   Python bit-true reference (SOURCE OF TRUTH)
│   ├── fixed_point.py          #   Q-format conversion utilities
│   ├── run_tests.ps1           #   Unified testbench runner
│   └── requirements.txt        #   Python dependencies
│
├── constraints/                # FPGA constraints
│   ├── tangnano9k.cst          #   Pin assignments
│   └── timing.sdc              #   Clock & timing constraints
│
├── docs/                       # Technical documentation
│   ├── tex/                    #   LaTeX source (fase0–4)
│   ├── figures/                #   Auto-generated plots
│   └── fixed_point_analysis.md #   Arithmetic design notes
│
└── gowin/                      # Gowin EDA project files
```

---

## Quick Start

### 1. Install Prerequisites

```bash
# Python 3.10+ with dependencies
pip install -r scripts/requirements.txt

# Icarus Verilog 12.0+ (via MSYS2 on Windows)
pacman -S mingw-w64-x86_64-iverilog
# Add C:\msys64\mingw64\bin to PATH
```

### 2. Generate Golden Model Vectors

```bash
python scripts/golden_model.py --nsym 256 --snr 20
```

**Outputs:**
- `sim/vectors/rrc_coeffs.{hex,mem,v}` — RRC filter coefficients
- `sim/vectors/qam16_symbols_{I,Q}.hex` — Reference constellation
- `sim/vectors/tx_filtered_{I,Q}.hex` — Pulse-shaped samples
- `docs/figures/*.png` — Constellation, eye diagram, spectrum plots

### 3. Run RTL Testbench Suite

```powershell
powershell -ExecutionPolicy Bypass -File scripts/run_tests.ps1
```

**Tests included:**

| Test                | Description                                  |
|---------------------|----------------------------------------------|
| QAM Mapper          | All 16 Gray-coded points vs truth table      |
| RRC Filter          | Impulse + 1024-vector comparison             |
| TX Top              | End-to-end transmit chain                    |
| AWGN Channel        | Noise sweep M=0…255, saturation checks       |
| RX Top              | Full modem + 5 kHz CFO stress test (≥75%)    |
| GDSP Top            | Phase 4 integration, PLL + HDMI connectivity |

### 4. FPGA Synthesis (Gowin EDA)

1. Open `gowin/gdsp_engine/gdsp_engine.gprj` in Gowin EDA IDE
2. Synthesise and place-and-route
3. Program the Tang Nano 9K via USB

**Physical Interface:**
- **Button S1**: Cycles noise level (0 → 20 → 50 → 100)
- **Button S2**: System reset
- **LED[0]**: Heartbeat (~0.8 Hz)
- **LED[1]**: Costas lock indicator
- **LED[3:2]**: Noise level (binary)
- **LED[4]**: PLL lock
- **HDMI**: Live 720p60 constellation display

---

## Development Phases

| Phase | Description                              | Status   |
|:-----:|------------------------------------------|:--------:|
| **0** | Project setup, golden model, Q-format    | ✅ Done  |
| **1** | QAM mapper + RRC pulse-shaping filter    | ✅ Done  |
| **2** | AWGN channel (CLT, N=16 LFSRs)          | ✅ Done  |
| **3** | Gardner TED + Costas loop (DD-PLL)       | ✅ Done  |
| **4** | System integration + HDMI visualisation  | ✅ Done  |

---

## Test Results Summary

| Metric                        | Result                          |
|-------------------------------|---------------------------------|
| **QAM Mapper**                | 16/16 points correct            |
| **RRC Filter**                | 1024/1024 samples ±2 LSB        |
| **TX Chain**                  | Symbols & timing verified       |
| **Channel**                   | Bypass + noise sweep OK         |
| **RX with 5 kHz CFO**         | Lock in ~326 sym, 81% accuracy  |
| **Costas NCO**                | ω converges to ≈ −48 (tracking) |

---

## Resource Estimation

| Resource      | Used (est.) | Available | Utilisation |
|---------------|------------:|----------:|:-----------:|
| LUTs          |      ~5,200 |     8,640 |     60%     |
| Flip-Flops    |      ~2,800 |     6,480 |     43%     |
| DSP (MULT9)   |           8 |        20 |     40%     |
| BSRAM (18kb)  |           4 |        26 |     15%     |
| PLL           |           1 |         2 |     50%     |

*Note: Actual usage varies with synthesis optimisation settings.*

---

## Project Documentation

Complete technical documentation in LaTeX (compile with `pdflatex`):

| Phase | Document | Description |
|:-----:|----------|-------------|
| 📘 **0** | [fase0\_analysis.tex](docs/tex/fase0_analysis.tex) | System parameters, Q1.11 fixed-point analysis |
| 📗 **1** | [fase1\_tx\_subsystem.tex](docs/tex/fase1_tx_subsystem.tex) | QAM mapper, RRC pulse-shaping filter |
| 📙 **2** | [fase2\_channel.tex](docs/tex/fase2_channel.tex) | AWGN channel model, CLT implementation |
| 📕 **3** | [fase3\_rx.tex](docs/tex/fase3_rx.tex) | Timing/carrier recovery, Costas loop |
| 📓 **4** | [fase4\_integration.tex](docs/tex/fase4_integration.tex) | Top-level integration, HDMI renderer |

Additional notes:
- [`docs/fixed_point_analysis.md`](docs/fixed_point_analysis.md) — Original Q-format design notes

---

## License

MIT — See [LICENSE](LICENSE) for details.

---

## Acknowledgements

- Sipeed for the Tang Nano 9K development board
- Gowin Semiconductor for the EDA toolchain
- The open-source FPGA community for Icarus Verilog
