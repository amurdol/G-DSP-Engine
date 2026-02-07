# ============================================================================
# G-DSP Engine — Fixed-Point Arithmetic Analysis
# ============================================================================
# Author : G-DSP Team
# Target : Gowin GW1NR-LV9QN88PC6/I5 (Tang Nano 9K)
# ============================================================================

## 1. DSP Slice Architecture on GW1NR-9

The GW1NR-LV9 contains **20 pREG/MULT9 DSP slices**. Each slice provides:
- One **9×9 signed** multiplier (native), or
- Cascaded as **18×18 signed** (2 slices), or **36×36** (4 slices).

For our 16-QAM baseband processor, the critical consumers of DSP slices are:
- **RRC FIR filter (Tx)** — pulse shaping
- **RRC FIR filter (Rx)** — matched filter
- **Gardner TED** — interpolation multiplies
- **Costas Loop** — NCO / complex multiply
- **AWGN generator** — Box-Muller (multiply + LUT)

**Budget allocation (target):**

| Block           | DSP Slices | Notes                             |
|-----------------|:----------:|-----------------------------------|
| RRC Tx (folded) | 2–4        | Semi-parallel, time-multiplexed   |
| RRC Rx (folded) | 2–4        | Same architecture                 |
| Gardner interp. | 2          | Linear interpolation (2 mults)    |
| Costas Loop     | 4          | Complex mult = 3 real mults + add |
| AWGN / misc     | 2–4        | Box-Muller approximation          |
| **Reserve**     | 2–4        | Timing closure / debug            |
| **TOTAL**       | ≤ 20       | ✓ Fits                            |

## 2. Fixed-Point Format Selection

### 2.1 Signal Levels in 16-QAM

Normalized 16-QAM constellation points on each axis: {±1, ±3} / √10.
- Maximum value: 3/√10 ≈ 0.9487
- After RRC filtering with overshoot (α=0.25): peak ≈ 1.15× symbol peak ≈ 1.09

We need dynamic range for: symbol × filter_coeff + accumulation.

### 2.2 Candidate Formats

| Format | Total bits | Range              | Resolution (LSB) | SQNR (dB) |
|--------|:----------:|--------------------|:-----------------:|:----------:|
| Q1.7   | 8          | [−1, +0.992]       | 7.81×10⁻³        | ~44 dB     |
| Q1.11  | 12         | [−1, +0.9995]      | 4.88×10⁻⁴        | ~68 dB     |
| Q1.15  | 16         | [−1, +0.99997]     | 3.05×10⁻⁵        | ~92 dB     |
| Q2.10  | 12         | [−2, +1.999]       | 9.77×10⁻⁴        | ~62 dB     |
| Q2.14  | 16         | [−2, +1.99994]     | 6.10×10⁻⁵        | ~86 dB     |

### 2.3 Decision: **Q1.11 (12-bit signed, two's complement)**

**Justification:**

1. **DSP Compatibility:** 12-bit inputs fit natively in the 18×18 Gowin
   multiplier (actually using a single MULT18 tile = 2 MULT9 slices).
   Product = 12 + 12 = 24 bits. The MULT18 output is 36 bits, so we have
   12 bits of headroom for accumulation directly inside the DSP primitive.

2. **SQNR margin:** 68 dB of signal-to-quantisation-noise ratio is 40+ dB
   above the minimum SNR for 16-QAM (≈20 dB for BER=10⁻⁵). The
   quantisation noise floor will be invisible.

3. **Filter overshoot:** The Q1.11 range [−1, +1) seems tight when peaks
   approach ±1.09 after filtering. However, we **pre-scale** the RRC
   coefficients so that the filter gain at its peak is ≤ 0.95. This is
   standard practice in ASIC/FPGA DSP pipelines — the Python Golden Model
   will enforce this normalization.

4. **Accumulator width:** For a 33-tap FIR:
   - Product: 24 bits
   - Accumulator: 24 + ceil(log2(33)) = 24 + 6 = **30 bits**
   - Final output: truncated back to 12 bits with convergent rounding.

5. **Resource efficiency:** 12 bits vs 16 bits saves ~25% in register and
   routing resources, which is critical on a 9K-LUT fabric.

### 2.4 Coefficient Normalization Strategy

The RRC filter coefficients `h[n]` will be normalized such that:
```
max(|h[n]|) = (2^(FRAC_BITS-1) - 1) / 2^FRAC_BITS
```
i.e., the largest tap is scaled to just under 0.5 in Q1.11, ensuring that
even with 4× oversampling and accumulation, we never overflow the 30-bit
accumulator. The Python model exports coefficients as **12-bit signed
integers** in two's complement.

## 3. Quantization Error Budget

| Stage           | Input (bits) | Output (bits) | Truncation Loss |
|-----------------|:------------:|:-------------:|:---------------:|
| QAM Mapper      | exact (LUT)  | 12            | None (exact)    |
| RRC Tx Filter   | 12           | 12            | ~0.5 LSB (round)|
| AWGN Addition   | 12 + 12      | 13 → 12       | ~0.5 LSB        |
| RRC Rx Filter   | 12           | 12            | ~0.5 LSB (round)|
| Gardner Interp. | 12           | 12            | ~0.5 LSB        |
| Costas Derot.   | 12           | 12            | ~0.5 LSB        |
| **Total accum.**|              |               | **~3 LSB worst**|

3 LSB in Q1.11 = 3 × 4.88×10⁻⁴ ≈ 1.46×10⁻³ — negligible vs. noise floor.

## 4. References

- Gowin GW1NR-LV9 Datasheet DS861, §5 "DSP Block"
- Lyons, R. "Understanding Digital Signal Processing", Ch. 12 (Fixed-Point)
- Proakis, J. "Digital Communications", 5th Ed., Ch. 5 (QAM)
