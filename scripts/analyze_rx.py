#!/usr/bin/env python3
"""Analyze RX constellation data."""
import csv
import numpy as np

# Leer CSV
data = []
with open("sim/vectors/rx_constellation.csv", "r") as f:
    reader = csv.DictReader(f)
    for row in reader:
        data.append(
            {
                "idx": int(row["sym_idx"]),
                "I": int(row["demod_I"]),
                "Q": int(row["demod_Q"]),
                "lock": int(row["locked"]),
            }
        )

# Filtrar solo locked y después de settle (400 símbolos post-lock)
lock_idx = next((d["idx"] for d in data if d["lock"] == 1), None)
print(f"Lock achieved at symbol: {lock_idx}")

# Tomar símbolos 400+ después del lock (settle time)
settle_start = lock_idx + 400 if lock_idx else 0
post_settle = [d for d in data if d["idx"] >= settle_start and d["lock"] == 1]

print(f"Post-settle samples (from sym {settle_start}): {len(post_settle)}")

# QAM levels
levels = [-1943, -648, 648, 1943]


def min_dist(val):
    return min(abs(val - l) for l in levels)


# Analizar distribución
correct = 0
tolerance = 300
for d in post_settle[:500]:
    di = min_dist(d["I"])
    dq = min_dist(d["Q"])
    if di <= tolerance and dq <= tolerance:
        correct += 1

print(f"Correct within tolerance: {correct}/500 = {100*correct/500:.1f}%")

# Ver estadísticas de los puntos
I_vals = [d["I"] for d in post_settle[:500]]
Q_vals = [d["Q"] for d in post_settle[:500]]
print(f"I range: [{min(I_vals)}, {max(I_vals)}], mean={np.mean(I_vals):.1f}")
print(f"Q range: [{min(Q_vals)}, {max(Q_vals)}], mean={np.mean(Q_vals):.1f}")

# Análizar si hay rotación - ver la distribución por cuadrante
quads = [0, 0, 0, 0]  # ++, +-, -+, --
for d in post_settle[:500]:
    q = (0 if d["I"] >= 0 else 2) + (0 if d["Q"] >= 0 else 1)
    quads[q] += 1
print(f"Cuadrantes [++, +-, -+, --]: {quads}")

# Ver algunos puntos extremos
print("\nEjemplos post-settle:")
for i in range(0, 50, 10):
    d = post_settle[i]
    print(
        f"  sym[{d['idx']}]: I={d['I']:5d} Q={d['Q']:5d} dist_I={min_dist(d['I']):3d} dist_Q={min_dist(d['Q']):3d}"
    )
