# ============================================================================
# G-DSP Engine — Fixed-Point Utilities
# ============================================================================
# *** SOURCE OF TRUTH ***
# This module defines the authoritative fixed-point format (Q1.11) and
# conversion functions used by both the Python golden model and verified
# against the RTL implementation. Any changes here must be reflected in
# rtl/packages/gdsp_pkg.sv.
# ============================================================================
# Provides Qn.m quantisation, saturation, rounding, and export to Verilog-
# compatible formats (.hex, .mem, .v include).
#
# Convention:
#   total_bits  = 1 (sign) + int_bits + frac_bits
#   Q{int_bits}.{frac_bits}  — e.g. Q1.11 → 12-bit signed
#
# All values are stored as Python floats internally; conversion to integer
# two's-complement happens only at export time.
# ============================================================================

from __future__ import annotations

import numpy as np
from pathlib import Path
from typing import Union, Sequence
from dataclasses import dataclass


@dataclass(frozen=True)
class QFormat:
    """
    Immutable descriptor for a Q-format fixed-point representation.

    Convention (TI-style):
        Qm.n → total_bits = m + n, where m includes the sign bit.
        E.g. Q1.11 → 1 sign bit + 11 fractional bits = 12 bits total.

    Internal representation:
        int_bits  = number of integer bits INCLUDING sign
        frac_bits = number of fractional bits
        total     = int_bits + frac_bits
    """

    int_bits: int  # Integer bits INCLUDING the sign bit (m in Qm.n)
    frac_bits: int  # Fractional bits (n in Qm.n)

    @property
    def total_bits(self) -> int:
        """Total width: int_bits (incl. sign) + frac_bits."""
        return self.int_bits + self.frac_bits

    @property
    def scale(self) -> int:
        """Scaling factor: 2^frac_bits."""
        return 1 << self.frac_bits

    @property
    def min_val(self) -> float:
        """Most negative representable value."""
        return -(1 << (self.int_bits - 1))

    @property
    def max_val(self) -> float:
        """Most positive representable value."""
        return (1 << (self.int_bits - 1)) - (1.0 / self.scale)

    @property
    def resolution(self) -> float:
        """Smallest step (1 LSB)."""
        return 1.0 / self.scale

    def __repr__(self) -> str:
        return f"Q{self.int_bits}.{self.frac_bits} ({self.total_bits}-bit signed)"


# Pre-defined project formats (TI Q notation: Qm.n, m includes sign bit)
Q1_11 = QFormat(int_bits=1, frac_bits=11)  # 12-bit: range [-1, +1), res=2^-11
Q2_10 = QFormat(int_bits=2, frac_bits=10)  # 12-bit: range [-2, +2), res=2^-10


def float_to_fixed(
    x: Union[float, np.ndarray],
    fmt: QFormat = Q1_11,
    rounding: str = "convergent",
) -> np.ndarray:
    """
    Convert floating-point value(s) to fixed-point integer representation.

    Parameters
    ----------
    x : float or ndarray
        Values to quantise.
    fmt : QFormat
        Target fixed-point format.
    rounding : str
        'floor', 'round', or 'convergent' (banker's rounding — default).

    Returns
    -------
    ndarray of int64
        Quantised values as signed integers in two's complement range.
    """
    x = np.asarray(x, dtype=np.float64)
    scaled = x * fmt.scale

    if rounding == "floor":
        q = np.floor(scaled)
    elif rounding == "round":
        q = np.round(scaled)
    elif rounding == "convergent":
        # Banker's rounding: round half to even
        q = np.where(
            np.abs(scaled - np.floor(scaled) - 0.5) < 1e-12,
            np.where(np.floor(scaled) % 2 == 0, np.floor(scaled), np.ceil(scaled)),
            np.round(scaled),
        )
    else:
        raise ValueError(f"Unknown rounding mode: {rounding}")

    q = q.astype(np.int64)

    # Saturate to representable range
    min_int = -(1 << (fmt.total_bits - 1))
    max_int = (1 << (fmt.total_bits - 1)) - 1
    clipped = np.clip(q, min_int, max_int)

    n_sat = int(np.sum(q != clipped))
    if n_sat > 0:
        print(f"[WARN] float_to_fixed: {n_sat} value(s) saturated in {fmt}")

    return clipped


def fixed_to_float(
    q: Union[int, np.ndarray],
    fmt: QFormat = Q1_11,
) -> np.ndarray:
    """Convert fixed-point integers back to floating-point."""
    return np.asarray(q, dtype=np.float64) / fmt.scale


def to_twos_complement(val: int, bits: int) -> int:
    """Convert a signed Python int to unsigned two's complement."""
    if val < 0:
        return val + (1 << bits)
    return val


# ============================================================================
# Export Functions
# ============================================================================


def export_hex(
    data: np.ndarray,
    filepath: Union[str, Path],
    fmt: QFormat = Q1_11,
    comment: str = "",
) -> Path:
    """
    Export fixed-point integers as a .hex file (one value per line).
    Each line is a hex string of width ceil(total_bits/4) characters.

    Compatible with Verilog's $readmemh().
    """
    filepath = Path(filepath)
    filepath.parent.mkdir(parents=True, exist_ok=True)
    hex_width = (fmt.total_bits + 3) // 4  # Number of hex digits

    with open(filepath, "w", encoding="utf-8") as f:
        if comment:
            f.write(f"// {comment}\n")
        f.write(f"// Format: {fmt}, {len(data)} values\n")
        for v in data:
            tc = to_twos_complement(int(v), fmt.total_bits)
            f.write(f"{tc:0{hex_width}X}\n")

    print(f"[INFO] Exported {len(data)} values -> {filepath}")
    return filepath


def export_mem(
    data: np.ndarray,
    filepath: Union[str, Path],
    fmt: QFormat = Q1_11,
    comment: str = "",
) -> Path:
    """
    Export as .mem file (binary strings) — compatible with $readmemb().
    """
    filepath = Path(filepath)
    filepath.parent.mkdir(parents=True, exist_ok=True)

    with open(filepath, "w", encoding="utf-8") as f:
        if comment:
            f.write(f"// {comment}\n")
        f.write(f"// Format: {fmt}, {len(data)} values\n")
        for v in data:
            tc = to_twos_complement(int(v), fmt.total_bits)
            f.write(f"{tc:0{fmt.total_bits}b}\n")

    print(f"[INFO] Exported {len(data)} values -> {filepath}")
    return filepath


def export_verilog_include(
    data: np.ndarray,
    filepath: Union[str, Path],
    fmt: QFormat = Q1_11,
    array_name: str = "COEFF",
    comment: str = "",
) -> Path:
    """
    Export as a Verilog include file (.vh / .v) with a function.

    Output example:
        function automatic signed [11:0] rrc_coeff(input int idx);
            case (idx)
                0: return 12'sh7FF;
                ...
            endcase
        endfunction

    This format is compatible with both iverilog and Gowin synthesizer.
    """
    filepath = Path(filepath)
    filepath.parent.mkdir(parents=True, exist_ok=True)
    n = len(data)
    w = fmt.total_bits

    # Generate function name from array_name (e.g., "RRC_COEFFS" -> "rrc_coeff")
    func_name = array_name.lower().rstrip("s")
    if func_name.endswith("_coeff"):
        pass  # already good
    else:
        func_name = func_name + "_coeff" if not func_name.endswith("coeff") else func_name

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(f"// Auto-generated by G-DSP Golden Model\n")
        if comment:
            f.write(f"// {comment}\n")
        f.write(f"// Format: {fmt}, {n} coefficients\n")
        f.write(f"// DO NOT EDIT -- regenerate with scripts/golden_model.py\n\n")

        f.write(f"localparam integer NUM_{array_name} = {n};\n\n")
        # Verilog-2001 compatible: no 'automatic', use 'integer' instead of 'int'
        f.write(f"function signed [{w-1}:0] {func_name};\n")
        f.write(f"    input integer idx;\n")
        f.write(f"    case (idx)\n")

        for i, v in enumerate(data):
            tc = to_twos_complement(int(v), w)
            # Show both hex and decimal for debugging
            # Use function name assignment (Verilog-2001 compatible) instead of return (SV only)
            f.write(
                f"        {i:2d}: {func_name} = {w}'sh{tc:0{(w+3)//4}X};"
                f"  // {int(v):+6d}  ({fixed_to_float(v, fmt):+.6f})\n"
            )

        f.write(f"        default: {func_name} = {w}'sh000;\n")
        f.write(f"    endcase\n")
        f.write(f"endfunction\n")

    print(f"[INFO] Exported Verilog include -> {filepath}")
    return filepath


def export_all(
    data: np.ndarray,
    base_path: Union[str, Path],
    fmt: QFormat = Q1_11,
    name: str = "rrc_coeffs",
    comment: str = "",
) -> dict[str, Path]:
    """Export in all three formats at once."""
    base = Path(base_path)
    return {
        "hex": export_hex(data, base / f"{name}.hex", fmt, comment),
        "mem": export_mem(data, base / f"{name}.mem", fmt, comment),
        "v": export_verilog_include(
            data, base / f"{name}.v", fmt, array_name=name.upper(), comment=comment
        ),
    }
