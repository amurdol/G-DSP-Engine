#!/usr/bin/env python3
# ============================================================================
# G-DSP Engine — RX Constellation Plotter
# ============================================================================
# Plots the actual demodulated symbols from tb_rx_top simulation.
# This shows the real constellation with ISI and noise effects.
#
# Usage:
#   python scripts/plot_rx_constellation.py
#   python scripts/plot_rx_constellation.py --csv sim/vectors/rx_constellation.csv
#   python scripts/plot_rx_constellation.py --no-save  # Don't save PNG
# ============================================================================

import sys
import argparse
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

# Project paths
SCRIPT_DIR = Path(__file__).parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_CSV = PROJECT_ROOT / "sim" / "vectors" / "rx_constellation.csv"
OUTPUT_DIR = PROJECT_ROOT / "docs" / "figures"


def load_rx_constellation(csv_path: Path) -> tuple:
    """
    Load demodulated symbols from tb_rx_top CSV output.

    CSV format: sym_idx,demod_I,demod_Q,locked

    Returns:
        (I_all, Q_all, I_locked, Q_locked) - arrays of I/Q values
    """
    print(f"Loading: {csv_path}")

    I_all, Q_all = [], []
    I_locked, Q_locked = [], []

    with open(csv_path, "r") as f:
        header = f.readline().strip()
        if header != "sym_idx,demod_I,demod_Q,locked":
            print(f"Warning: Unexpected header: {header}")

        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 4:
                continue

            try:
                idx = int(parts[0])
                I = int(parts[1])
                Q = int(parts[2])
                locked = int(parts[3])

                I_all.append(I)
                Q_all.append(Q)

                if locked:
                    I_locked.append(I)
                    Q_locked.append(Q)
            except ValueError:
                continue

    print(f"  Total symbols: {len(I_all)}")
    print(f"  Locked symbols: {len(I_locked)}")

    return (np.array(I_all), np.array(Q_all), np.array(I_locked), np.array(Q_locked))


def plot_constellation(
    I: np.ndarray,
    Q: np.ndarray,
    title: str = "16-QAM Constellation",
    subtitle: str = None,
    show_ideal: bool = True,
    output_path: Path = None,
):
    """
    Plot IQ constellation diagram.

    Args:
        I, Q: Arrays of I/Q values in Q1.11 format (-2048 to +2047)
        title: Plot title
        subtitle: Optional subtitle
        show_ideal: Show ideal 16-QAM grid
        output_path: Path to save PNG (None = don't save)
    """
    # Ideal 16-QAM levels (Q1.11 format)
    # Levels: ±0.316 (±648) and ±0.948 (±1943)
    IDEAL_LEVELS = [-1943, -648, 648, 1943]

    fig, ax = plt.subplots(figsize=(8, 8))

    # Plot ideal constellation grid
    if show_ideal:
        for i_level in IDEAL_LEVELS:
            for q_level in IDEAL_LEVELS:
                ax.scatter(i_level, q_level, c="lightgray", s=200, marker="o", alpha=0.5, zorder=1)

    # Plot received symbols
    ax.scatter(I, Q, c="blue", s=10, alpha=0.5, zorder=2, label="RX symbols")

    # Formatting
    ax.set_xlim(-2500, 2500)
    ax.set_ylim(-2500, 2500)
    ax.set_aspect("equal")
    ax.axhline(0, color="gray", linewidth=0.5, alpha=0.5)
    ax.axvline(0, color="gray", linewidth=0.5, alpha=0.5)
    ax.grid(True, alpha=0.3)
    ax.set_xlabel("In-Phase (I)", fontsize=12)
    ax.set_ylabel("Quadrature (Q)", fontsize=12)

    # Title
    full_title = title
    if subtitle:
        full_title += f"\n{subtitle}"
    ax.set_title(full_title, fontsize=14)

    # Stats annotation
    stats_text = (
        f"Symbols: {len(I):,}\nRange I: [{I.min()}, {I.max()}]\nRange Q: [{Q.min()}, {Q.max()}]"
    )
    ax.text(
        0.02,
        0.98,
        stats_text,
        transform=ax.transAxes,
        fontsize=9,
        verticalalignment="top",
        fontfamily="monospace",
        bbox=dict(boxstyle="round", facecolor="white", alpha=0.8),
    )

    plt.tight_layout()

    # Save
    if output_path:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        plt.savefig(output_path, dpi=150, bbox_inches="tight")
        print(f"Saved: {output_path}")

    return fig, ax


def main():
    parser = argparse.ArgumentParser(description="Plot RX constellation from tb_rx_top output")
    parser.add_argument(
        "--csv",
        type=Path,
        default=DEFAULT_CSV,
        help=f"Path to CSV file (default: {DEFAULT_CSV.relative_to(PROJECT_ROOT)})",
    )
    parser.add_argument("--no-save", action="store_true", help="Don't save PNG file")
    parser.add_argument("--show", action="store_true", help="Show interactive plot window")
    parser.add_argument("--all", action="store_true", help="Plot all symbols (not just locked)")
    args = parser.parse_args()

    # Check CSV exists
    if not args.csv.exists():
        print(f"ERROR: CSV file not found: {args.csv}")
        print(f"Run: .\\scripts\\run_tests.ps1 (RX Top test generates this file)")
        return 1

    # Load data
    I_all, Q_all, I_locked, Q_locked = load_rx_constellation(args.csv)

    if len(I_locked) == 0:
        print("WARNING: No locked symbols found! Using all symbols.")
        I_plot, Q_plot = I_all, Q_all
        subtitle = "All symbols (no lock detected)"
    elif args.all:
        I_plot, Q_plot = I_all, Q_all
        subtitle = f"All {len(I_all):,} symbols"
    else:
        I_plot, Q_plot = I_locked, Q_locked
        subtitle = f"Locked symbols ({len(I_locked):,} of {len(I_all):,})"

    # Output path
    output_path = None if args.no_save else OUTPUT_DIR / "constellation_rx_sim.png"

    # Plot
    plot_constellation(
        I_plot,
        Q_plot,
        title="16-QAM RX Constellation (Simulation)",
        subtitle=subtitle,
        show_ideal=True,
        output_path=output_path,
    )

    if args.show:
        plt.show()

    print("\nDone!")
    return 0


if __name__ == "__main__":
    sys.exit(main())
