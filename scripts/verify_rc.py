#!/usr/bin/env python3
"""Verify raised cosine from RRC coefficients."""
import numpy as np

# Read coefficients from the generated file
coeffs_q = []
with open("sim/vectors/rrc_coeffs.mem", "r") as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("//"):
            coeffs_q.append(int(line, 16) if len(line) == 3 else int(line))

# Convert from unsigned hex to signed if needed
coeffs_q = np.array(coeffs_q, dtype=np.int16)
for i in range(len(coeffs_q)):
    if coeffs_q[i] > 2047:
        coeffs_q[i] -= 4096

scale = 2048.0
h_rrc = coeffs_q / scale

print(f"RRC coefficients ({len(h_rrc)} taps, Q1.11):")
print(f"  Raw: {coeffs_q.tolist()}")
print(f"  Normalized: {h_rrc}")
print(f"  Sum: {np.sum(h_rrc):.4f}")
print(f"  Energy: {np.sum(h_rrc**2):.4f}")

# Raised cosine = convolution of RRC with itself
h_rc = np.convolve(h_rrc, h_rrc)
print(f"\nRaised cosine length: {len(h_rc)}")
print(f"Raised cosine values:")
for i, val in enumerate(h_rc):
    marker = " <-- center" if i == len(h_rc) // 2 else ""
    print(f"  h_rc[{i}] = {val:8.5f}{marker}")

# Check ISI: at symbol intervals (SPS=4), values should be 0 except center
print("\n=== ISI Check (SPS=4) ===")
center = len(h_rc) // 2
print(f"Center index: {center}")

sps = 4
sym_indices = range(0, len(h_rc), sps)
print("Values at symbol intervals:")
for idx in sym_indices:
    val = h_rc[idx] if idx < len(h_rc) else 0
    is_center = "*** MAIN ***" if idx == center else ("ISI" if abs(val) > 0.001 else "OK ~0")
    print(f"  sample[{idx:2d}]: {val:8.5f}  {is_center}")

# The problem: with 7-tap filter and SPS=4, the raised cosine has 13 taps
# The optimal sampling points are at indices that are multiples of SPS
# But the filter response spans:
span_symbols = len(h_rc) / sps
print(f"\nFilter span: {len(h_rc)} samples = {span_symbols:.2f} symbols")
print(f"Peak response at index {center} = sample {center/sps:.2f} in symbol units")

# For ISI-free operation, we need to sample at offset where the center aligns
# with a multiple of SPS
print("\n=== Optimal sampling alignment ===")
for phase in range(sps):
    # Sample at indices: phase, phase+4, phase+8, ...
    samples = [h_rc[i] if i < len(h_rc) else 0 for i in range(phase, len(h_rc) + sps, sps)]
    peak_idx = np.argmax(np.abs(samples))
    print(f"Phase {phase}: peak at position {peak_idx} = {samples[peak_idx]:.4f}")
    print(f"         ISI: {[f'{s:.3f}' for s in samples]}")
