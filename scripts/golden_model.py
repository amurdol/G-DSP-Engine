# ============================================================================
# G-DSP Engine — Python Golden Model (Phase 0)
# ============================================================================
# *** SOURCE OF TRUTH FOR TESTBENCHES ***
# This script is the bit-true reference for the FPGA implementation.
# All RTL testbenches load vectors generated here from sim/vectors/.
# Parameters: Q1.11 (12-bit), RRC α=0.25, 33 taps, SPS=4, 16-QAM Gray.
# ============================================================================
# This script is the bit-true reference for the FPGA implementation.
# It generates, modulates, filters, and exports all data needed for
# hardware verification.
#
# Usage:
#   python scripts/golden_model.py            (default: 256 symbols)
#   python scripts/golden_model.py --nsym 1024 --snr 15
#
# Outputs:
#   sim/vectors/rrc_coeffs.hex   — RRC taps for $readmemh
#   sim/vectors/rrc_coeffs.mem   — RRC taps for $readmemb
#   sim/vectors/rrc_coeffs.v     — Verilog localparam include
#   sim/vectors/tx_symbols.hex   — Transmitted 16-QAM symbols (I, Q)
#   sim/vectors/tx_filtered.hex  — Pulse-shaped output samples
#   docs/figures/*.png           — Constellation, eye, spectrum plots
# ============================================================================

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import matplotlib

matplotlib.use("Agg")  # Non-interactive backend for CI/headless
import matplotlib.pyplot as plt
from scipy import signal as sig

# Local imports
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fixed_point import QFormat, Q1_11, float_to_fixed, fixed_to_float, export_hex, export_all

# ============================================================================
# Project root (relative to this script)
# ============================================================================
PROJECT_ROOT = Path(__file__).resolve().parent.parent
VECTOR_DIR = PROJECT_ROOT / "sim" / "vectors"
FIGURE_DIR = PROJECT_ROOT / "docs" / "figures"

VECTOR_DIR.mkdir(parents=True, exist_ok=True)
FIGURE_DIR.mkdir(parents=True, exist_ok=True)


# ############################################################################
# 1. 16-QAM GRAY-CODED MAPPER
# ############################################################################

# Gray-coded 16-QAM constellation (4 bits → I, Q)
# Mapping: b3 b2 → I-axis,  b1 b0 → Q-axis
# Each axis uses Gray: 00→-3, 01→-1, 11→+1, 10→+3
# Normalized by 1/√10 so average power = 1.

_GRAY_MAP_AXIS = {
    0b00: -3,
    0b01: -1,
    0b11: +1,
    0b10: +3,
}

# Full 16-QAM table: index = 4-bit symbol, value = (I, Q) un-normalized
QAM16_TABLE = {}
for sym in range(16):
    i_bits = (sym >> 2) & 0x3
    q_bits = sym & 0x3
    QAM16_TABLE[sym] = (_GRAY_MAP_AXIS[i_bits], _GRAY_MAP_AXIS[q_bits])

# Normalisation factor
QAM16_NORM = 1.0 / np.sqrt(10.0)


def generate_bits(n_bits: int, seed: int = 42) -> np.ndarray:
    """Generate a pseudo-random binary sequence."""
    rng = np.random.default_rng(seed)
    return rng.integers(0, 2, size=n_bits, dtype=np.uint8)


def bits_to_symbols(bits: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """
    Map bit stream to 16-QAM symbols.

    Parameters
    ----------
    bits : ndarray of uint8
        Must have length divisible by 4.

    Returns
    -------
    I, Q : ndarray of float64
        Normalised in-phase and quadrature components.
    """
    assert len(bits) % 4 == 0, f"Bit length {len(bits)} not divisible by 4"
    n_sym = len(bits) // 4

    I = np.empty(n_sym)
    Q = np.empty(n_sym)

    for k in range(n_sym):
        nibble = (
            (bits[4 * k] << 3) | (bits[4 * k + 1] << 2) | (bits[4 * k + 2] << 1) | bits[4 * k + 3]
        )
        i_raw, q_raw = QAM16_TABLE[nibble]
        I[k] = i_raw * QAM16_NORM
        Q[k] = q_raw * QAM16_NORM

    return I, Q


def print_qam16_table():
    """Pretty-print the 16-QAM mapping table."""
    print("\n16-QAM Gray-Coded Constellation Map:")
    print("=" * 60)
    print(f"{'Symbol':>8} {'Bits':>6} {'I_raw':>6} {'Q_raw':>6}" f" {'I_norm':>10} {'Q_norm':>10}")
    print("-" * 60)
    for sym in range(16):
        i_raw, q_raw = QAM16_TABLE[sym]
        print(
            f"{sym:>8d} {sym:>06b} {i_raw:>+6d} {q_raw:>+6d}"
            f" {i_raw*QAM16_NORM:>+10.6f} {q_raw*QAM16_NORM:>+10.6f}"
        )
    print()


# ############################################################################
# 2. ROOT-RAISED COSINE (RRC) FILTER DESIGN
# ############################################################################


def design_rrc(
    num_taps: int = 33,
    sps: int = 4,
    alpha: float = 0.25,
) -> np.ndarray:
    """
    Design a Root-Raised Cosine (RRC) filter.

    Parameters
    ----------
    num_taps : int
        Filter length (must be odd for symmetry).
    sps : int
        Samples per symbol (oversampling factor).
    alpha : float
        Roll-off factor (0 < α ≤ 1).

    Returns
    -------
    h : ndarray
        RRC impulse response, normalised to unit energy.

    Notes
    -----
    Uses the analytical formula from Proakis (Digital Communications, 5e).
    The filter is symmetric (Type I linear phase).
    """
    assert num_taps % 2 == 1, "num_taps must be odd for Type-I symmetry"
    N = num_taps
    Ts = sps  # Symbol period in samples

    # Time index centred at 0
    n = np.arange(N) - (N - 1) / 2
    t = n / Ts  # Normalised time (in symbol periods)

    h = np.zeros(N)

    for i, ti in enumerate(t):
        if abs(ti) < 1e-12:
            # t = 0
            h[i] = 1 - alpha + 4 * alpha / np.pi
        elif abs(abs(ti) - 1 / (4 * alpha)) < 1e-12:
            # t = ±1/(4α) — the problematic points
            h[i] = (alpha / np.sqrt(2)) * (
                (1 + 2 / np.pi) * np.sin(np.pi / (4 * alpha))
                + (1 - 2 / np.pi) * np.cos(np.pi / (4 * alpha))
            )
        else:
            num = np.sin(np.pi * ti * (1 - alpha)) + 4 * alpha * ti * np.cos(
                np.pi * ti * (1 + alpha)
            )
            den = np.pi * ti * (1 - (4 * alpha * ti) ** 2)
            h[i] = num / den

    # Normalise to unit energy (so matched filter pair has unit gain)
    h /= np.sqrt(np.sum(h**2))

    return h


def rrc_to_fixed(
    h: np.ndarray,
    fmt: QFormat = Q1_11,
) -> np.ndarray:
    """
    Scale and quantise RRC coefficients to fixed-point.

    Strategy: scale so that max(|h|) maps to ~0.45 in Q1.11 range.
    This leaves headroom for accumulation in the FIR and prevents overflow.
    """
    # Scale so peak coefficient ≈ 0.45 (well within [-1, +1))
    peak_target = 0.45
    scale_factor = peak_target / np.max(np.abs(h))
    h_scaled = h * scale_factor

    print(f"\n[RRC Fixed-Point Conversion]")
    print(f"  Original peak : {np.max(np.abs(h)):.6f}")
    print(f"  Scale factor  : {scale_factor:.6f}")
    print(f"  Scaled peak   : {np.max(np.abs(h_scaled)):.6f}")
    print(f"  Target format : {fmt}")

    h_fixed = float_to_fixed(h_scaled, fmt)

    # Quantisation error analysis
    h_reconstructed = fixed_to_float(h_fixed, fmt)
    quant_error = h_scaled - h_reconstructed
    sqnr = 10 * np.log10(np.sum(h_scaled**2) / np.sum(quant_error**2))
    print(f"  SQNR          : {sqnr:.1f} dB")
    print(f"  Max quant err : {np.max(np.abs(quant_error)):.6e}")

    return h_fixed, h_scaled, scale_factor


# ############################################################################
# 3. SIGNAL CHAIN
# ############################################################################


def upsample_and_filter(
    I: np.ndarray,
    Q: np.ndarray,
    h: np.ndarray,
    sps: int = 4,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Upsample symbols by SPS and apply pulse-shaping RRC filter.

    Parameters
    ----------
    I, Q : symbol arrays (float)
    h    : RRC impulse response
    sps  : samples per symbol

    Returns
    -------
    I_tx, Q_tx : filtered, oversampled I/Q signal
    """
    # Zero-insert upsampling
    I_up = np.zeros(len(I) * sps)
    Q_up = np.zeros(len(Q) * sps)
    I_up[::sps] = I
    Q_up[::sps] = Q

    # Convolve with RRC (linear convolution, trim to same length)
    I_tx = np.convolve(I_up, h, mode="same")
    Q_tx = np.convolve(Q_up, h, mode="same")

    return I_tx, Q_tx


def add_awgn(
    I: np.ndarray,
    Q: np.ndarray,
    snr_db: float,
    seed: int = 123,
) -> tuple[np.ndarray, np.ndarray]:
    """Add AWGN noise to achieve desired Eb/N0 for 16-QAM."""
    rng = np.random.default_rng(seed)
    # Signal power (should be ≈1 if normalised)
    sig_power = np.mean(I**2 + Q**2)
    # Noise variance per dimension
    noise_var = sig_power / (2 * 10 ** (snr_db / 10))
    noise_std = np.sqrt(noise_var)

    I_noisy = I + rng.normal(0, noise_std, len(I))
    Q_noisy = Q + rng.normal(0, noise_std, len(Q))

    actual_snr = 10 * np.log10(sig_power / (2 * noise_var))
    print(f"  AWGN: target SNR = {snr_db:.1f} dB, actual = {actual_snr:.1f} dB")

    return I_noisy, Q_noisy


# ############################################################################
# 4. PLOTTING
# ############################################################################


def plot_constellation(
    I: np.ndarray,
    Q: np.ndarray,
    title: str = "16-QAM Constellation",
    filename: str = "constellation.png",
    show_ideal: bool = True,
):
    """Plot IQ constellation diagram."""
    fig, ax = plt.subplots(1, 1, figsize=(7, 7))
    ax.scatter(I, Q, s=2, alpha=0.4, c="steelblue", label="Received")

    if show_ideal:
        # Plot ideal constellation points
        for sym in range(16):
            i_raw, q_raw = QAM16_TABLE[sym]
            ax.plot(i_raw * QAM16_NORM, q_raw * QAM16_NORM, "r+", markersize=14, markeredgewidth=2)

    ax.set_xlabel("In-Phase (I)")
    ax.set_ylabel("Quadrature (Q)")
    ax.set_title(title)
    ax.set_aspect("equal")
    ax.grid(True, alpha=0.3)
    ax.axhline(0, color="k", linewidth=0.5)
    ax.axvline(0, color="k", linewidth=0.5)
    ax.set_xlim([-1.5, 1.5])
    ax.set_ylim([-1.5, 1.5])

    path = FIGURE_DIR / filename
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[PLOT] Saved -> {path}")


def plot_spectrum(
    I: np.ndarray,
    Q: np.ndarray,
    fs: float,
    title: str = "Signal Spectrum",
    filename: str = "spectrum.png",
):
    """Plot power spectral density of the complex baseband signal."""
    x = I + 1j * Q
    N = len(x)
    X = np.fft.fftshift(np.fft.fft(x, n=max(N, 4096)))
    freqs = np.fft.fftshift(np.fft.fftfreq(len(X), d=1.0 / fs))
    psd = 20 * np.log10(np.abs(X) / np.max(np.abs(X)) + 1e-12)

    fig, ax = plt.subplots(1, 1, figsize=(10, 5))
    ax.plot(freqs, psd, linewidth=0.7, color="steelblue")
    ax.set_xlabel("Frequency (normalised to symbol rate)")
    ax.set_ylabel("PSD (dB)")
    ax.set_title(title)
    ax.set_ylim([-80, 5])
    ax.grid(True, alpha=0.3)
    ax.axhline(-3, color="r", linestyle="--", linewidth=0.5, label="-3 dB")
    ax.legend()

    path = FIGURE_DIR / filename
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[PLOT] Saved -> {path}")


def plot_eye_diagram(
    signal: np.ndarray,
    sps: int = 4,
    n_traces: int = 200,
    title: str = "Eye Diagram",
    filename: str = "eye_diagram.png",
):
    """Plot an eye diagram for timing analysis."""
    trace_len = 2 * sps  # 2 symbols per trace
    fig, ax = plt.subplots(1, 1, figsize=(8, 5))

    for i in range(min(n_traces, len(signal) // trace_len - 1)):
        start = i * sps + sps // 2  # Offset for centering
        if start + trace_len > len(signal):
            break
        segment = signal[start : start + trace_len]
        t = np.arange(trace_len) / sps
        ax.plot(t, segment, color="steelblue", alpha=0.15, linewidth=0.5)

    ax.set_xlabel("Time (symbol periods)")
    ax.set_ylabel("Amplitude")
    ax.set_title(title)
    ax.grid(True, alpha=0.3)

    path = FIGURE_DIR / filename
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[PLOT] Saved -> {path}")


def plot_rrc_filter(
    h: np.ndarray,
    h_fixed_float: np.ndarray,
    sps: int = 4,
    filename: str = "rrc_impulse.png",
):
    """Plot RRC impulse response: ideal vs quantised."""
    n = np.arange(len(h)) - (len(h) - 1) / 2
    t = n / sps

    fig, axes = plt.subplots(2, 1, figsize=(10, 8))

    # Impulse response
    ax = axes[0]
    ax.stem(t, h, linefmt="b-", markerfmt="bo", basefmt="k-", label="Float (scaled)")
    ax.stem(
        t, h_fixed_float, linefmt="r-", markerfmt="r^", basefmt="k-", label="Fixed-point (Q1.11)"
    )
    ax.set_xlabel("Time (symbol periods)")
    ax.set_ylabel("Amplitude")
    ax.set_title("RRC Impulse Response — Float vs Fixed-Point")
    ax.legend()
    ax.grid(True, alpha=0.3)

    # Frequency response
    ax = axes[1]
    w_f, H_f = sig.freqz(h, worN=2048, fs=sps)
    w_q, H_q = sig.freqz(h_fixed_float, worN=2048, fs=sps)
    ax.plot(w_f, 20 * np.log10(np.abs(H_f) + 1e-12), "b-", linewidth=1.5, label="Float")
    ax.plot(w_q, 20 * np.log10(np.abs(H_q) + 1e-12), "r--", linewidth=1.5, label="Fixed-point")
    ax.set_xlabel("Frequency (normalised)")
    ax.set_ylabel("|H(f)| (dB)")
    ax.set_title("RRC Frequency Response")
    ax.set_ylim([-80, 5])
    ax.legend()
    ax.grid(True, alpha=0.3)

    fig.tight_layout()
    path = FIGURE_DIR / filename
    fig.savefig(path, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[PLOT] Saved -> {path}")


# ############################################################################
# 5. VECTOR EXPORT FOR VERILOG TESTBENCHES
# ############################################################################


def export_iq_vectors(
    I: np.ndarray,
    Q: np.ndarray,
    name: str,
    fmt: QFormat = Q1_11,
):
    """Export I/Q sample pairs as separate .hex files for Verilog $readmemh."""
    I_fixed = float_to_fixed(I, fmt)
    Q_fixed = float_to_fixed(Q, fmt)

    export_hex(I_fixed, VECTOR_DIR / f"{name}_I.hex", fmt, comment=f"{name} In-Phase samples")
    export_hex(Q_fixed, VECTOR_DIR / f"{name}_Q.hex", fmt, comment=f"{name} Quadrature samples")

    return I_fixed, Q_fixed


# ############################################################################
# 6. MAIN — RUN THE FULL GOLDEN MODEL PIPELINE
# ############################################################################


def main():
    parser = argparse.ArgumentParser(description="G-DSP Engine — 16-QAM Golden Model")
    parser.add_argument(
        "--nsym", type=int, default=256, help="Number of 16-QAM symbols (default: 256)"
    )
    parser.add_argument("--sps", type=int, default=4, help="Samples per symbol (default: 4)")
    parser.add_argument(
        "--ntaps", type=int, default=33, help="RRC filter taps (default: 33, must be odd)"
    )
    parser.add_argument(
        "--alpha", type=float, default=0.25, help="RRC roll-off factor (default: 0.25)"
    )
    parser.add_argument("--snr", type=float, default=20.0, help="SNR in dB for AWGN (default: 20)")
    parser.add_argument("--seed", type=int, default=42, help="Random seed (default: 42)")
    parser.add_argument("--no-plots", action="store_true", help="Skip plot generation")

    args = parser.parse_args()

    print("=" * 70)
    print("  G-DSP Engine — 16-QAM Golden Model")
    print("=" * 70)
    print(f"  Symbols      : {args.nsym}")
    print(f"  SPS          : {args.sps}")
    print(f"  RRC taps     : {args.ntaps}")
    print(f"  Roll-off (α) : {args.alpha}")
    print(f"  SNR          : {args.snr} dB")
    print(f"  Fixed-point  : {Q1_11}")
    print(f"  Output dir   : {VECTOR_DIR}")
    print("=" * 70)

    # ------------------------------------------------------------------
    # Step 1: Generate random bits
    # ------------------------------------------------------------------
    n_bits = args.nsym * 4  # 4 bits per 16-QAM symbol
    bits = generate_bits(n_bits, seed=args.seed)
    print(f"\n[1] Generated {n_bits} random bits (first 32: {bits[:32]})")

    # ------------------------------------------------------------------
    # Step 2: Map to 16-QAM symbols
    # ------------------------------------------------------------------
    print_qam16_table()
    I_sym, Q_sym = bits_to_symbols(bits)
    print(f"[2] Mapped to {args.nsym} 16-QAM symbols")
    print(f"    Signal power: {np.mean(I_sym**2 + Q_sym**2):.4f} (expect ≈1.0)")

    # Export ideal symbols
    export_iq_vectors(I_sym, Q_sym, "qam16_symbols", Q1_11)

    # ------------------------------------------------------------------
    # Step 3: Design RRC filter
    # ------------------------------------------------------------------
    h_rrc = design_rrc(num_taps=args.ntaps, sps=args.sps, alpha=args.alpha)
    print(f"\n[3] Designed RRC filter: {args.ntaps} taps, α={args.alpha}")
    print(f"    Symmetry check: max|h[n]-h[N-1-n]| = " f"{np.max(np.abs(h_rrc - h_rrc[::-1])):.2e}")

    # Quantise to fixed-point
    h_fixed, h_scaled, scale_factor = rrc_to_fixed(h_rrc, Q1_11)

    # Export coefficients in all formats
    export_all(
        h_fixed,
        VECTOR_DIR,
        Q1_11,
        name="rrc_coeffs",
        comment=f"RRC α={args.alpha}, {args.ntaps} taps, SPS={args.sps}",
    )

    # ------------------------------------------------------------------
    # Step 4: Transmit pulse shaping
    # ------------------------------------------------------------------
    print(f"\n[4] Applying Tx pulse-shaping filter...")
    I_tx, Q_tx = upsample_and_filter(I_sym, Q_sym, h_scaled, sps=args.sps)
    print(f"    Tx signal length: {len(I_tx)} samples")
    print(f"    Tx peak: I={np.max(np.abs(I_tx)):.4f}, Q={np.max(np.abs(Q_tx)):.4f}")

    # Also compute with fixed-point coefficients for bit-true comparison
    h_fixed_float = fixed_to_float(h_fixed, Q1_11)
    I_tx_q, Q_tx_q = upsample_and_filter(I_sym, Q_sym, h_fixed_float, sps=args.sps)

    # Export Tx vectors
    export_iq_vectors(I_tx_q, Q_tx_q, "tx_filtered", Q1_11)

    # ------------------------------------------------------------------
    # Step 5: Add AWGN
    # ------------------------------------------------------------------
    print(f"\n[5] Adding AWGN channel noise...")
    I_rx, Q_rx = add_awgn(I_tx_q, Q_tx_q, snr_db=args.snr, seed=args.seed + 1)

    # Export noisy Rx vectors
    export_iq_vectors(I_rx, Q_rx, "rx_noisy", Q1_11)

    # ------------------------------------------------------------------
    # Step 6: Matched filter (Rx RRC)
    # ------------------------------------------------------------------
    print(f"\n[6] Applying Rx matched filter...")
    I_mf = np.convolve(I_rx, h_fixed_float, mode="same")
    Q_mf = np.convolve(Q_rx, h_fixed_float, mode="same")
    print(f"    MF output peak: I={np.max(np.abs(I_mf)):.4f}, " f"Q={np.max(np.abs(Q_mf)):.4f}")

    # Downsample at symbol rate (optimal sampling point)
    # Delay = (ntaps-1)/2 samples from each filter = ntaps-1 total
    delay = args.ntaps - 1
    I_dec = I_mf[delay :: args.sps]
    Q_dec = Q_mf[delay :: args.sps]

    # Trim to original symbol count
    min_len = min(len(I_dec), len(Q_dec), args.nsym)
    I_dec = I_dec[:min_len]
    Q_dec = Q_dec[:min_len]

    # ------------------------------------------------------------------
    # Step 7: Plots
    # ------------------------------------------------------------------
    if not args.no_plots:
        print(f"\n[7] Generating plots...")

        plot_constellation(
            I_sym,
            Q_sym,
            title="16-QAM Ideal Constellation (Tx)",
            filename="constellation_tx.png",
            show_ideal=True,
        )

        plot_constellation(
            I_dec,
            Q_dec,
            title=f"16-QAM After Matched Filter (SNR={args.snr} dB)",
            filename="constellation_rx.png",
            show_ideal=True,
        )

        plot_spectrum(
            I_tx_q,
            Q_tx_q,
            fs=args.sps,
            title=f"Tx Spectrum (α={args.alpha}, Fixed-Point RRC)",
            filename="spectrum_tx.png",
        )

        plot_eye_diagram(
            I_tx_q, sps=args.sps, title="Eye Diagram — I-channel (Tx)", filename="eye_diagram_I.png"
        )

        plot_rrc_filter(h_scaled, h_fixed_float, sps=args.sps)

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    print("\n" + "=" * 70)
    print("  GOLDEN MODEL COMPLETE")
    print("=" * 70)
    print(f"  Vectors exported to : {VECTOR_DIR}")
    print(f"  Figures exported to : {FIGURE_DIR}")
    print(f"  Files generated:")
    for f in sorted(VECTOR_DIR.glob("*")):
        if f.is_file() and f.name != "README.md":
            print(f"    • {f.name}")
    print("=" * 70)


if __name__ == "__main__":
    main()
