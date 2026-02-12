#!/usr/bin/env python3
"""
G-DSP Engine — RX Chain Debug Script
=====================================
Simulates TX → Channel → RX to debug Costas Loop.
"""

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from pathlib import Path

SPS = 4
NUM_TAPS = 5
ALPHA = 0.35
NUM_SYMBOLS = 500
QAM_SCALE = 2048 / np.sqrt(10)

OUTPUT_DIR = Path(__file__).parent.parent / "docs" / "figures"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

GRAY_MAP = {0b00: -3, 0b01: -1, 0b11: +1, 0b10: +3}


def qam16_map(symbols_4bit):
    I = np.array([GRAY_MAP[(s >> 2) & 0x3] / np.sqrt(10) for s in symbols_4bit])
    Q = np.array([GRAY_MAP[s & 0x3] / np.sqrt(10) for s in symbols_4bit])
    return I, Q


def design_rrc(num_taps, sps, alpha):
    N = num_taps
    n = np.arange(N) - (N - 1) / 2
    t = n / sps
    h = np.zeros(N)
    for i, ti in enumerate(t):
        if abs(ti) < 1e-12:
            h[i] = 1 - alpha + 4 * alpha / np.pi
        elif abs(abs(ti) - 1 / (4 * alpha)) < 1e-12:
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
    h /= np.sqrt(np.sum(h**2))
    return h


def tx_process(I_sym, Q_sym, h):
    I_up = np.zeros(len(I_sym) * SPS)
    Q_up = np.zeros(len(Q_sym) * SPS)
    I_up[::SPS] = I_sym
    Q_up[::SPS] = Q_sym
    return np.convolve(I_up, h, mode="same"), np.convolve(Q_up, h, mode="same")


def channel(I, Q, phase_deg=0, cfo_hz=0, fs_hz=27e6):
    n = len(I)
    phase_init = np.deg2rad(phase_deg)
    if cfo_hz != 0:
        t = np.arange(n) / fs_hz
        phase = phase_init + 2 * np.pi * cfo_hz * t
    else:
        phase = np.full(n, phase_init)
    I_rot = I * np.cos(phase) - Q * np.sin(phase)
    Q_rot = I * np.sin(phase) + Q * np.cos(phase)
    return I_rot, Q_rot


def rx_matched_filter(I, Q, h):
    I_mf = np.convolve(I, h, mode="same")
    Q_mf = np.convolve(Q, h, mode="same")
    # Normalize by peak of cascade response (h*h) at optimal sampling point
    cascade_response = np.convolve(h, h, mode="full")
    peak_gain = np.max(cascade_response)  # Peak at center = optimal sample point
    print(
        f"  [DEBUG MF] cascade peak: {peak_gain:.3f}, cascade sum: {np.sum(cascade_response):.3f}"
    )
    return I_mf / peak_gain, Q_mf / peak_gain


def gardner_ted_simple(I_mf, Q_mf):
    skip = NUM_TAPS // 2
    return I_mf[skip * SPS :: SPS], Q_mf[skip * SPS :: SPS]


def costas_loop_float(sym_I, sym_Q, initial_phase_deg=0, Kp=0.1, Ki=0.01):
    """Costas loop - de-rotates by -phase to REMOVE channel rotation."""
    n = len(sym_I)
    demod_I = np.zeros(n)
    demod_Q = np.zeros(n)
    phase_trace = np.zeros(n)
    omega_trace = np.zeros(n)
    error_trace = np.zeros(n)

    phase = np.deg2rad(initial_phase_deg)
    omega = 0.0
    slicer_th = 2 / np.sqrt(10)

    def slice_qam(x):
        if x < -slicer_th:
            return -3 / np.sqrt(10)
        elif x < 0:
            return -1 / np.sqrt(10)
        elif x < slicer_th:
            return +1 / np.sqrt(10)
        else:
            return +3 / np.sqrt(10)

    for i in range(n):
        I_in, Q_in = sym_I[i], sym_Q[i]

        # De-rotate by -phase (conjugate rotation to remove channel phase)
        cos_p = np.cos(-phase)
        sin_p = np.sin(-phase)
        rot_I = I_in * cos_p - Q_in * sin_p
        rot_Q = I_in * sin_p + Q_in * cos_p

        demod_I[i], demod_Q[i] = rot_I, rot_Q

        I_hat = slice_qam(rot_I)
        Q_hat = slice_qam(rot_Q)

        # Phase error (cross-product DD)
        phase_err = rot_I * Q_hat - rot_Q * I_hat
        error_trace[i] = phase_err

        # PI Loop filter
        omega += Ki * phase_err
        phase += omega + Kp * phase_err
        phase = np.mod(phase + np.pi, 2 * np.pi) - np.pi

        phase_trace[i] = np.rad2deg(phase)
        omega_trace[i] = omega

    return demod_I, demod_Q, phase_trace, omega_trace, error_trace


def plot_constellation(I, Q, title, filename):
    fig, ax = plt.subplots(figsize=(8, 8))
    I_plot = I * QAM_SCALE * np.sqrt(10)
    Q_plot = Q * QAM_SCALE * np.sqrt(10)
    ax.scatter(I_plot, Q_plot, s=3, alpha=0.5, c="steelblue")
    for i_lvl in [-1943, -648, 648, 1943]:
        for q_lvl in [-1943, -648, 648, 1943]:
            ax.plot(i_lvl, q_lvl, "r+", markersize=15, markeredgewidth=2)
    ax.set_xlabel("I")
    ax.set_ylabel("Q")
    ax.set_title(title)
    ax.set_xlim([-2500, 2500])
    ax.set_ylim([-2500, 2500])
    ax.set_aspect("equal")
    ax.grid(True, alpha=0.3)
    fig.savefig(OUTPUT_DIR / filename, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[PLOT] {OUTPUT_DIR / filename}")


def plot_loop_traces(phase, omega, error, filename):
    fig, axes = plt.subplots(3, 1, figsize=(12, 8), sharex=True)
    x = np.arange(len(phase))
    axes[0].plot(x, phase, "b-", linewidth=0.5)
    axes[0].set_ylabel("Phase (deg)")
    axes[0].grid(True)
    axes[1].plot(x, omega, "g-", linewidth=0.5)
    axes[1].set_ylabel("Omega")
    axes[1].grid(True)
    axes[2].plot(x, error, "m-", linewidth=0.5)
    axes[2].set_ylabel("Error")
    axes[2].set_xlabel("Symbol")
    axes[2].grid(True)
    fig.savefig(OUTPUT_DIR / filename, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"[PLOT] {OUTPUT_DIR / filename}")


def main():
    print("=" * 60)
    print("G-DSP Engine — RX Chain Debug")
    print("=" * 60)

    h = design_rrc(NUM_TAPS, SPS, ALPHA)
    print(f"RRC coeffs: {h}")
    print(f"Cascade gain: {np.sum(np.convolve(h, h, mode='full')):.2f}")

    rng = np.random.default_rng(42)
    symbols = rng.integers(0, 16, NUM_SYMBOLS, dtype=np.uint8)
    I_sym, Q_sym = qam16_map(symbols)

    # TEST 0: Verify Costas Loop in isolation (no RRC, no upsampling)
    print("\n" + "=" * 60)
    print("[TEST 0] Costas Loop in isolation (direct symbols)")
    print("=" * 60)

    for phase_deg in [0, 45, 90, 135]:
        phase_rad = np.deg2rad(phase_deg)
        I_rot = I_sym * np.cos(phase_rad) - Q_sym * np.sin(phase_rad)
        Q_rot = I_sym * np.sin(phase_rad) + Q_sym * np.cos(phase_rad)

        I_demod, Q_demod, phase, omega, error = costas_loop_float(I_rot, Q_rot, Kp=0.1, Ki=0.01)

        # Count match with any 90deg rotation (16-QAM ambiguity)
        settle = 100
        n_check = len(I_demod) - settle
        best_acc = 0
        best_rot = 0
        for test_rot in [0, 90, 180, 270]:
            theta = np.deg2rad(test_rot)
            I_test = I_demod * np.cos(theta) - Q_demod * np.sin(theta)
            Q_test = I_demod * np.sin(theta) + Q_demod * np.cos(theta)
            correct = 0
            for k in range(n_check):
                idx = settle + k
                tol = 0.1 / np.sqrt(10)
                if abs(I_test[idx] - I_sym[idx]) < tol and abs(Q_test[idx] - Q_sym[idx]) < tol:
                    correct += 1
            if correct > best_acc:
                best_acc = correct
                best_rot = test_rot
        print(
            f"  Channel {phase_deg:3d}°: final_phase={phase[-1]:+7.1f}°, accuracy={100*best_acc/n_check:5.1f}% (w/ +{best_rot}° ambiguity)"
        )

    print("\n" + "=" * 60)
    print("[TESTS 1-3] Full TX/RX Chain")
    print("=" * 60)

    I_tx, Q_tx = tx_process(I_sym, Q_sym, h)

    tests = [
        {"phase": 0, "cfo": 0, "label": "No impairments"},
        {"phase": 45, "cfo": 0, "label": "45 deg phase"},
        {"phase": 90, "cfo": 0, "label": "90 deg phase"},
    ]

    for i, tc in enumerate(tests):
        print(f"\n[Test {i+1}] {tc['label']}...")

        I_ch, Q_ch = channel(I_tx, Q_tx, phase_deg=tc["phase"], cfo_hz=tc["cfo"])
        I_mf, Q_mf = rx_matched_filter(I_ch, Q_ch, h)
        I_ted, Q_ted = gardner_ted_simple(I_mf, Q_mf)

        plot_constellation(
            I_ted, Q_ted, f"Before Costas: {tc['label']}", f"debug_{i+1:02d}a_before.png"
        )

        I_demod, Q_demod, phase, omega, error = costas_loop_float(I_ted, Q_ted, Kp=0.1, Ki=0.01)

        plot_constellation(
            I_demod, Q_demod, f"After Costas: {tc['label']}", f"debug_{i+1:02d}b_after.png"
        )
        plot_loop_traces(phase, omega, error, f"debug_{i+1:02d}c_traces.png")

        # Debug: print expected vs actual for first few symbols after settling
        print(f"  Final phase: {phase[-1]:.1f} deg, omega: {omega[-1]:.4f}")

        # Show sample of demodulated symbols
        print(f"  Sample demod I: {I_demod[-10:]}")
        print(f"  Sample demod Q: {Q_demod[-10:]}")
        print(
            f"  Expected levels: {[-3, -1, 1, 3]} / sqrt(10) = {np.array([-3,-1,1,3])/np.sqrt(10)}"
        )

        # Skip symbols during settling (first ~100 symbols)
        settle = 200
        n_check = len(I_demod) - settle
        if n_check > 0:
            correct = 0
            # Gardner TED offset: skip = NUM_TAPS // 2 = 2, so demod[k] corresponds to I_sym[k + skip]
            offset = NUM_TAPS // 2
            for k in range(n_check):
                demod_idx = settle + k
                ref_idx = demod_idx + offset
                if ref_idx < len(I_sym):
                    tol = 0.5 / np.sqrt(10)
                    if (
                        abs(I_demod[demod_idx] - I_sym[ref_idx]) < tol
                        and abs(Q_demod[demod_idx] - Q_sym[ref_idx]) < tol
                    ):
                        correct += 1
            print(f"  Accuracy (after settle): {correct}/{n_check} ({100*correct/n_check:.0f}%)")

        # Check for 90deg ambiguity: rotate by 90, 180, 270 and check accuracy
        for rot in [0, 90, 180, 270]:
            theta = np.deg2rad(rot)
            I_rot = I_demod * np.cos(theta) - Q_demod * np.sin(theta)
            Q_rot = I_demod * np.sin(theta) + Q_demod * np.cos(theta)
            correct = 0
            offset = NUM_TAPS // 2
            for k in range(n_check):
                demod_idx = settle + k
                ref_idx = demod_idx + offset
                if ref_idx < len(I_sym):
                    tol = 0.5 / np.sqrt(10)
                    if (
                        abs(I_rot[demod_idx] - I_sym[ref_idx]) < tol
                        and abs(Q_rot[demod_idx] - Q_sym[ref_idx]) < tol
                    ):
                        correct += 1
            if correct > 0:
                print(
                    f"  -> With +{rot}° rotation: {correct}/{n_check} ({100*correct/n_check:.0f}%)"
                )


if __name__ == "__main__":
    main()
