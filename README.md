# G-DSP Engine

> **16-QAM Baseband Processor with Real-Time HDMI Visualisation**
> Final Degree Project (TFG) — FPGA-based DSP on Gowin GW1NR-9

---

## Overview

G-DSP Engine is a fully hardware-implemented 16-QAM digital communications
transceiver running on the **Sipeed Tang Nano 9K** (Gowin GW1NR-LV9).
It performs modulation, pulse shaping, noise injection, matched filtering,
timing/carrier recovery, and renders the IQ constellation in **720p @ 60 Hz
over HDMI** — all in real time, with no soft-core CPU in the data path.

## Architecture

```
┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐
│  PRBS   │──▶│ 16-QAM   │──▶│  RRC Tx  │──▶│   AWGN   │──▶│  RRC Rx  │
│ Bit Gen │   │ Mapper   │   │ Pulse    │   │ Channel  │   │ Matched  │
│         │   │ (Gray)   │   │ Shaping  │   │  (CLT)   │   │ Filter   │
└─────────┘   └──────────┘   └──────────┘   └──────────┘   └──────────┘
                                                                 │
┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐        │
│  HDMI   │◀──│ Constel. │◀──│  Costas  │◀──│ Gardner  │◀───────┘
│ 720p60  │   │ Renderer │   │  Loop    │   │ Timing   │
│ (PSRAM) │   │          │   │(Carrier) │   │ Recovery │
└─────────┘   └──────────┘   └──────────┘   └──────────┘
```

## Hardware Target

| Parameter       | Value                                    |
|-----------------|------------------------------------------|
| **FPGA**        | Gowin GW1NR-LV9QN88PC6/I5               |
| **LUTs**        | 8,640                                    |
| **DSP Slices**  | 20 (MULT9/pREG)                          |
| **BSRAM**       | 26 × 18 Kbit                             |
| **PSRAM**       | 64 Mbit HyperRAM (frame buffer)          |
| **Video Out**   | HDMI 720p @ 60 Hz (TMDS)                 |
| **Clock**       | 27 MHz oscillator → PLL to system/pixel  |

## Fixed-Point Format

**Q1.11** — 12-bit signed, two's complement.

- Range: $[-1.0, +1.0 - 2^{-11}]$
- Resolution (1 LSB): $2^{-11} \approx 4.88 \times 10^{-4}$
- SQNR: ~68 dB (40+ dB above 16-QAM operating point)

See [`docs/fixed_point_analysis.md`](docs/fixed_point_analysis.md) for the
full derivation and DSP resource budget.

## Repository Structure

```
G-DSP-Engine/
├── rtl/                          # Synthesisable RTL (SystemVerilog)
│   ├── packages/                 #   Global parameters (gdsp_pkg.sv)
│   ├── top/                      #   Top-level integration
│   ├── modem/                    #   QAM mapper, RRC filters
│   ├── channel/                  #   AWGN noise generator
│   ├── sync/                     #   Gardner TED, Costas Loop
│   ├── video/                    #   HDMI TX, constellation renderer
│   ├── memory/                   #   PSRAM controller
│   └── common/                   #   Shared utilities (bit gen, etc.)
├── sim/                          # Simulation & verification
│   ├── tb/                       #   SystemVerilog testbenches
│   ├── cocotb/                   #   Python-driven co-simulation
│   ├── vectors/                  #   Stimulus / reference data (.hex)
│   └── waves/                    #   Waveform dumps (git-ignored)
├── constraints/                  # Pin (.cst) and timing (.sdc) files
├── scripts/                      # Python Golden Model & utilities
│   ├── golden_model.py           #   Full 16-QAM reference chain
│   ├── fixed_point.py            #   Qn.m conversion & export
│   └── requirements.txt          #   Python dependencies
├── docs/                         # Technical documentation
│   ├── fixed_point_analysis.md   #   Arithmetic justification
│   └── figures/                  #   Auto-generated plots
└── README.md                     # ← You are here
```

## Quick Start

### 1. Python Golden Model

```bash
# Install dependencies
pip install -r scripts/requirements.txt

# Run the golden model (generates vectors + plots)
python scripts/golden_model.py --nsym 256 --snr 20

# Custom parameters
python scripts/golden_model.py --nsym 1024 --alpha 0.25 --ntaps 33 --snr 15
```

Outputs:
- `sim/vectors/rrc_coeffs.{hex,mem,v}` — RRC filter taps for Verilog
- `sim/vectors/qam16_symbols_{I,Q}.hex` — Reference constellation points
- `sim/vectors/tx_filtered_{I,Q}.hex` — Pulse-shaped Tx samples
- `docs/figures/*.png` — Constellation, spectrum, eye diagram plots

### 2. FPGA Build (Gowin EDA)

```bash
# Open project in Gowin EDA IDE and synthesise
# Or use command-line flow (when configured):
# gw_sh run.tcl
```

## Development Phases

| Phase | Description                              | Status       |
|:-----:|------------------------------------------|:------------:|
| **0** | Setup, Golden Model, Fixed-Point         | Done         |
| **1** | RTL: QAM Mapper + RRC FIR Filter         | Done         |
| **2** | RTL: AWGN Channel (CLT, N=16)            | Done         |
| **3** | RTL: Gardner TED + Costas Loop           | Planned      |
| **4** | Integration, Timing Closure, Demo        | Planned      |

## License

MIT — See [LICENSE](LICENSE) for details.
