"""
G-DSP Engine — Visualizador de Constelación 16-QAM
Simula la salida HDMI del renderizador de constelación
"""

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from pathlib import Path
import os

# Obtener directorio raíz del proyecto (un nivel arriba de scripts/)
project_root = Path(__file__).parent.parent
output_dir = project_root / "docs" / "figures"
output_dir.mkdir(parents=True, exist_ok=True)

# Parámetros de 16-QAM (niveles normalizados según gdsp_pkg.sv)
# QAM_NEG3 = -1943, QAM_NEG1 = -648, QAM_POS1 = 648, QAM_POS3 = 1943
# En formato Q1.11: rango [-2048, 2047]
QAM_LEVELS = np.array([-1943, -648, 648, 1943]) / 2048.0  # Normalizado a [-1, 1]

# Generar constelación 16-QAM ideal
constellation = []
labels = []
for q_idx, q_val in enumerate(QAM_LEVELS):
    for i_idx, i_val in enumerate(QAM_LEVELS):
        constellation.append((i_val, q_val))
        # Etiqueta binaria (4 bits): [Q1 Q0 I1 I0]
        label = (q_idx << 2) | i_idx
        labels.append(label)

constellation = np.array(constellation)
I_points = constellation[:, 0]
Q_points = constellation[:, 1]

# Determinar color por cuadrante (igual que en constellation_renderer.sv)
colors = []
for i, q in zip(I_points, Q_points):
    if i >= 0 and q >= 0:
        colors.append("#00FFFF")  # Q1: Cyan
    elif i < 0 and q >= 0:
        colors.append("#00FF00")  # Q2: Green
    elif i < 0 and q < 0:
        colors.append("#FFFF00")  # Q3: Yellow
    else:  # i >= 0 and q < 0
        colors.append("#FF00FF")  # Q4: Magenta

# Crear figura con fondo negro (igual que HDMI)
fig, ax = plt.subplots(figsize=(10, 10), facecolor="black")
ax.set_facecolor("black")

# Dibujar área de gráfica (256x256 pixels centered on 640x480)
plot_rect = Rectangle((-1, -1), 2, 2, linewidth=1, edgecolor="#404040", facecolor="black", zorder=0)
ax.add_patch(plot_rect)

# Ejes de referencia (I=0, Q=0) en gris
ax.axhline(0, color="#404040", linewidth=1.5, linestyle="-", zorder=1)
ax.axvline(0, color="#404040", linewidth=1.5, linestyle="-", zorder=1)

# Líneas de decisión (límites entre símbolos) en azul oscuro
# Decisión en ±1296 / 2048 = ±0.633
decision_boundary = 1296 / 2048.0
ax.axhline(decision_boundary, color="#202040", linewidth=1, linestyle="--", alpha=0.7, zorder=1)
ax.axhline(-decision_boundary, color="#202040", linewidth=1, linestyle="--", alpha=0.7, zorder=1)
ax.axvline(decision_boundary, color="#202040", linewidth=1, linestyle="--", alpha=0.7, zorder=1)
ax.axvline(-decision_boundary, color="#202040", linewidth=1, linestyle="--", alpha=0.7, zorder=1)

# Dibujar puntos de la constelación ideal (grandes, como 4x4 pixels)
ax.scatter(
    I_points,
    Q_points,
    c=colors,
    s=400,
    marker="o",
    edgecolors="white",
    linewidths=1,
    zorder=3,
    alpha=0.9,
)

# Añadir etiquetas binarias a cada punto
for i, (x, y, label) in enumerate(zip(I_points, Q_points, labels)):
    # Formato: 4 bits en binario
    bin_label = f"{label:04b}"
    ax.text(
        x,
        y,
        bin_label,
        fontsize=7,
        ha="center",
        va="center",
        color="black",
        weight="bold",
        zorder=4,
    )

# Simular ruido AWGN (símbolos recibidos con dispersión)
np.random.seed(42)  # Reproducible
num_symbols = 200  # Símbolos recibidos
snr_db = 15  # SNR en dB (ajustable)

# Generar símbolos aleatorios
tx_symbols = constellation[np.random.randint(0, 16, num_symbols)]

# Añadir ruido gaussiano
noise_power = 10 ** (-snr_db / 10)
noise_I = np.random.normal(0, np.sqrt(noise_power / 2), num_symbols)
noise_Q = np.random.normal(0, np.sqrt(noise_power / 2), num_symbols)
rx_I = tx_symbols[:, 0] + noise_I
rx_Q = tx_symbols[:, 1] + noise_Q

# Determinar color de símbolos ruidosos por cuadrante
rx_colors = []
for i, q in zip(rx_I, rx_Q):
    if i >= 0 and q >= 0:
        rx_colors.append("#00FFFF")  # Cyan
    elif i < 0 and q >= 0:
        rx_colors.append("#00FF00")  # Green
    elif i < 0 and q < 0:
        rx_colors.append("#FFFF00")  # Yellow
    else:
        rx_colors.append("#FF00FF")  # Magenta

# Dibujar símbolos recibidos con ruido (más pequeños, semi-transparentes)
ax.scatter(rx_I, rx_Q, c=rx_colors, s=100, marker="o", alpha=0.5, edgecolors="none", zorder=2)

# Configuración de ejes
ax.set_xlim(-1.2, 1.2)
ax.set_ylim(-1.2, 1.2)
ax.set_aspect("equal")
ax.set_xlabel("In-phase (I)", color="white", fontsize=14)
ax.set_ylabel("Quadrature (Q)", color="white", fontsize=14)
ax.set_title(
    "16-QAM Constellation — G-DSP Engine\n"
    + f"Símbolos ideales (grandes) + Recibidos con AWGN SNR={snr_db} dB (pequeños)",
    color="white",
    fontsize=16,
    pad=20,
)
ax.tick_params(colors="white")
ax.grid(False)

# Leyenda de colores
legend_elements = [
    plt.Line2D(
        [0],
        [0],
        marker="o",
        color="w",
        markerfacecolor="#00FFFF",
        markersize=10,
        label="Q1: +I, +Q (Cyan)",
        linestyle="None",
    ),
    plt.Line2D(
        [0],
        [0],
        marker="o",
        color="w",
        markerfacecolor="#00FF00",
        markersize=10,
        label="Q2: -I, +Q (Green)",
        linestyle="None",
    ),
    plt.Line2D(
        [0],
        [0],
        marker="o",
        color="w",
        markerfacecolor="#FFFF00",
        markersize=10,
        label="Q3: -I, -Q (Yellow)",
        linestyle="None",
    ),
    plt.Line2D(
        [0],
        [0],
        marker="o",
        color="w",
        markerfacecolor="#FF00FF",
        markersize=10,
        label="Q4: +I, -Q (Magenta)",
        linestyle="None",
    ),
]
legend = ax.legend(
    handles=legend_elements,
    loc="upper left",
    facecolor="#202020",
    edgecolor="white",
    labelcolor="white",
    fontsize=10,
)

plt.tight_layout()

# Guardar imagen en docs/figures/
output_file = output_dir / "constellation_16qam.png"
plt.savefig(output_file, dpi=150, facecolor="black", bbox_inches="tight")
print(f"[OK] Grafica guardada: {output_file}")
print(f"[OK] Simbolos ideales: 16 (grandes, con etiquetas binarias)")
print(f"[OK] Simbolos recibidos: {num_symbols} (pequenos, con ruido SNR={snr_db} dB)")
print(f"\nLo que deberias ver en tu monitor HDMI:")
print(f"  - 4 colores distintos (uno por cuadrante)")
print(f"  - Nube de puntos alrededor de cada simbolo ideal")
print(f"  - Ejes grises en el centro (I=0, Q=0)")
print(f"  - Lineas azules punteadas (limites de decision)")
print(f"\n[OK] Abre '{output_file}' para ver la referencia")
