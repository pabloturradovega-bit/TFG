"""Figures and animations for the README (English, Spanish and French versions).

Uses only data already in this repository (Resultados/Sobol_512_L1000_C80_S235JR): the 512 Sobol
designs, their force-displacement curves (Sim_NNN/Curvas.csv) and the validated optimum
(Sim_VAL_Cat_1). Nothing is simulated. Output: docs/img/.

Run from the repository root:  python docs/make_figures.py
Requires: numpy, pandas, matplotlib, pillow.
"""
from pathlib import Path

import matplotlib
import numpy as np
import pandas as pd

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib import animation  # noqa: E402
from matplotlib.patches import Polygon, Rectangle  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CAMP = ROOT / "Resultados" / "Sobol_512_L1000_C80_S235JR"
OUT = ROOT / "docs" / "img"
OUT.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 13})

# Figures reported in the thesis (Chapter 5) for this campaign
SEA_OPT_VALIDATED = 469.0       # J/kg, optimum re-simulated in ANSYS (Sim_VAL_Cat_1)
SEA_OPT_PREDICTED = 457.7       # J/kg, surrogate prediction for that design

TXT = {
    "en": {"disp": "Lateral displacement [mm]", "force": "Force [kN]", "sea": "SEA [J/kg]",
           "curves_title": "512 simulated designs (Sobol campaign) and the validated optimum",
           "opt": "Validated optimum (469.0 J/kg)", "cbar": "Specific energy absorbed, SEA [J/kg]",
           "sim": "Simulation number (Sobol order)", "best": "Best simulated so far",
           "anim_title": "Sampling 512 designs vs. surrogate + genetic algorithm",
           "star": "Optimum found by GPR + GA,\nvalidated in ANSYS: 469.0 J/kg",
           "hist_title": "SEA of the 512 simulated designs", "mean": "Mean", "bestsim": "Best simulated",
           "designs": "Designs"},
    "es": {"disp": "Desplazamiento lateral [mm]", "force": "Fuerza [kN]", "sea": "SEA [J/kg]",
           "curves_title": "Los 512 diseños simulados (campaña Sobol) y el óptimo validado",
           "opt": "Óptimo validado (469,0 J/kg)", "cbar": "Energía específica absorbida, SEA [J/kg]",
           "sim": "Número de simulación (orden Sobol)", "best": "Mejor simulado hasta ese momento",
           "anim_title": "Muestrear 512 diseños frente a modelo sustituto + algoritmo genético",
           "star": "Óptimo hallado con GPR + GA,\nvalidado en ANSYS: 469,0 J/kg",
           "hist_title": "SEA de los 512 diseños simulados", "mean": "Media", "bestsim": "Mejor simulado",
           "designs": "Diseños"},
    "fr": {"disp": "Déplacement latéral [mm]", "force": "Force [kN]", "sea": "SEA [J/kg]",
           "curves_title": "Les 512 conceptions simulées (campagne Sobol) et l'optimum validé",
           "opt": "Optimum validé (469,0 J/kg)", "cbar": "Énergie spécifique absorbée, SEA [J/kg]",
           "sim": "Numéro de simulation (ordre de Sobol)", "best": "Meilleure simulée jusqu'ici",
           "anim_title": "Échantillonner 512 conceptions ou métamodèle + algorithme génétique",
           "star": "Optimum trouvé par GPR + AG,\nvalidé dans ANSYS : 469,0 J/kg",
           "hist_title": "SEA des 512 conceptions simulées", "mean": "Moyenne",
           "bestsim": "Meilleure simulée", "designs": "Conceptions"},
}


def load():
    data = pd.read_csv(CAMP / "dataset_512_muestras_limpio.csv")
    curves = []
    for i in range(len(data)):
        c = pd.read_csv(CAMP / f"Sim_{i + 1:03d}" / "Curvas.csv")
        curves.append((np.abs(c["DispX"].to_numpy()) * 1000, np.abs(c["ForceX"].to_numpy()) / 1000))
    c = pd.read_csv(CAMP / "Sim_VAL_Cat_1" / "Curvas.csv")
    opt = (np.abs(c["DispX"].to_numpy()) * 1000, np.abs(c["ForceX"].to_numpy()) / 1000)
    return data, curves, opt


def fig_curves(data, curves, opt, lang):
    t = TXT[lang]
    sea = data["energy_per_mass"].to_numpy()
    cmap, norm = plt.cm.viridis, plt.Normalize(np.percentile(sea, 2), sea.max())
    fig, ax = plt.subplots(figsize=(11, 6))
    for k in np.argsort(sea):
        d, f = curves[k]
        ax.plot(np.r_[0, d], np.r_[0, f], color=cmap(norm(sea[k])), lw=0.7, alpha=0.55)
    ax.plot(np.r_[0, opt[0]], np.r_[0, opt[1]], color="#d62728", lw=3.2, label=t["opt"])
    sm = plt.cm.ScalarMappable(cmap=cmap, norm=norm)
    fig.colorbar(sm, ax=ax, label=t["cbar"])
    ax.set_xlabel(t["disp"])
    ax.set_ylabel(t["force"])
    ax.set_title(t["curves_title"], fontsize=14)
    ax.set_xlim(0, 500)
    ax.set_ylim(0, None)
    ax.grid(alpha=0.3)
    ax.legend(loc="upper left", fontsize=13)
    fig.tight_layout()
    fig.savefig(OUT / f"curves_{lang}.png", dpi=110)
    plt.close(fig)


def fig_hist(data, lang):
    t = TXT[lang]
    sea = data["energy_per_mass"].to_numpy()
    fig, ax = plt.subplots(figsize=(10, 4.8))
    ax.hist(sea, bins=40, color="#7f9cc0", edgecolor="white")
    dec = (lambda v: f"{v:.1f}") if lang == "en" else (lambda v: f"{v:.1f}".replace(".", ","))
    ax.axvline(sea.mean(), color="k", lw=2.2, ls="--", label=f"{t['mean']}: {dec(sea.mean())} J/kg")
    ax.axvline(sea.max(), color="#2c7fb8", lw=2.2, label=f"{t['bestsim']}: {dec(sea.max())} J/kg")
    ax.axvline(SEA_OPT_VALIDATED, color="#d62728", lw=2.6, label=t["opt"])
    ax.legend(loc="upper right", fontsize=13)
    ax.set_xlabel(t["sea"])
    ax.set_ylabel(t["designs"])
    ax.set_title(t["hist_title"], fontsize=14)
    ax.set_xlim(0, 500)
    ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(OUT / f"sea_hist_{lang}.png", dpi=110)
    plt.close(fig)


def anim_search(data, lang):
    """Sobol designs appear one by one with the running best; at the end, the validated optimum."""
    t = TXT[lang]
    sea = data["energy_per_mass"].to_numpy()
    n = len(sea)
    best = np.maximum.accumulate(sea)
    steps = list(range(8, n + 1, 8))
    frames = steps + [n] * 18          # pause at the end with the optimum shown
    fig, ax = plt.subplots(figsize=(9, 5))
    ax.set_xlim(0, n + 10)
    ax.set_ylim(0, 520)
    ax.set_xlabel(t["sim"])
    ax.set_ylabel(t["sea"])
    ax.set_title(t["anim_title"], fontsize=13)
    ax.grid(alpha=0.3)
    pts = ax.scatter([], [], s=10, color="#7f9cc0")
    line, = ax.plot([], [], color="#2c7fb8", lw=2.5, label=t["best"])
    star = ax.scatter([], [], s=320, marker="*", color="#d62728", zorder=5)
    txt = ax.text(n * 0.42, 488, "", color="#d62728", fontsize=12, va="top")
    ax.legend(loc="lower right", fontsize=12)

    def update(k):
        pts.set_offsets(np.column_stack([np.arange(1, k + 1), sea[:k]]))
        line.set_data(np.arange(1, k + 1), best[:k])
        if k == n:
            star.set_offsets([[n + 4, SEA_OPT_VALIDATED]])
            txt.set_text(t["star"])
        else:
            star.set_offsets(np.empty((0, 2)))
            txt.set_text("")
        return pts, line, star, txt

    ani = animation.FuncAnimation(fig, update, frames=frames, blit=False)
    ani.save(OUT / f"search_{lang}.gif", writer=animation.PillowWriter(fps=12), dpi=80)
    plt.close(fig)


def fig_geometry():
    """Side view of the L-joint with the design variables (symbols only: language-neutral)."""
    a1, a2, c, L = 100, 80, 80, 520          # drawing proportions (not to scale in length)
    fig, ax = plt.subplots(figsize=(7.5, 7.5))
    steel, gus = "#9fb3c8", "#e8a87c"
    ax.add_patch(Rectangle((0, 0), a1, L, fc=steel, ec="k", lw=1.5))                 # pillar
    ax.add_patch(Rectangle((a1, 0), L - 60, a2, fc=steel, ec="k", lw=1.5))           # beam
    ax.add_patch(Polygon([[a1, a2], [a1 + c, a2], [a1, a2 + c]], fc=gus, ec="k", lw=1.5))
    for x in np.arange(a1 - 10, L + a1 - 60, 22):                                     # clamped base
        ax.plot([x, x - 14], [0, -14], color="k", lw=1)
    ax.plot([a1, L + a1 - 60], [0, 0], color="k", lw=2.5)
    ax.annotate("", xy=(-90, L - 15), xytext=(-10, L - 15),
                arrowprops=dict(arrowstyle="-|>", lw=3, color="#d62728"))
    ax.text(-95, L + 8, "u = 500 mm", color="#d62728", fontsize=14)

    def dim(x0, y0, x1, y1, label, off=(0, 0), **kw):
        ax.annotate("", xy=(x0, y0), xytext=(x1, y1), arrowprops=dict(arrowstyle="<->", lw=1.3))
        ax.text((x0 + x1) / 2 + off[0], (y0 + y1) / 2 + off[1], label, fontsize=15, ha="center", **kw)

    dim(0, L + 35, a1, L + 35, "$a_1$", (0, 8))
    dim(L + a1 - 40, 0, L + a1 - 40, a2, "$a_2$", (22, -6))
    dim(a1 + 4, a2 + c + 18, a1 + c + 4, a2 + 18, "$c$", (22, 12))
    ax.text(a1 / 2, L * 0.55, "$m_1$", ha="center", fontsize=16)
    ax.text(a1 + 230, a2 / 2 - 8, "$m_2$", ha="center", fontsize=16)
    ax.text(a1 + c / 3 - 2, a2 + c / 3 - 6, "$e$", ha="center", fontsize=15)
    # Tube cross-section (inset): side a (in the drawing plane) × width b (out of plane), wall m
    ox, oy, A, B, tt = a1 + 200, L * 0.55, 90, 130, 12
    ax.add_patch(Rectangle((ox, oy), B, A, fc=steel, ec="k", lw=1.5))
    ax.add_patch(Rectangle((ox + tt, oy + tt), B - 2 * tt, A - 2 * tt, fc="white", ec="k", lw=1.2))
    dim(ox, oy - 18, ox + B, oy - 18, "$b$", (0, -30))
    dim(ox + B + 18, oy, ox + B + 18, oy + A, "$a$", (18, -6))
    ax.text(ox + B / 2, oy + A + 14, "$m$", ha="center", fontsize=15)
    ax.text(ox + B / 2, oy + A + 48, "$l_1 = l_2 = 1000$ mm", ha="center", fontsize=13)
    ax.set_xlim(-130, L + a1)
    ax.set_ylim(-40, L + 70)
    ax.set_aspect("equal")
    ax.axis("off")
    fig.tight_layout()
    fig.savefig(OUT / "geometry.png", dpi=110)
    plt.close(fig)


def anim_gallery():
    """Von Mises stress at 500 mm (ANSYS screenshots) for several designs: language-neutral."""
    data = pd.read_csv(CAMP / "dataset_512_muestras_limpio.csv")
    picks = [("Sim_VAL_Cat_1", None), ("Sim_235", 234), ("Sim_019", 18), ("Sim_197", 196), ("Sim_196", 195)]
    frames = []
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 26)
    except OSError:
        font = ImageFont.truetype(str(Path(matplotlib.get_data_path()) / "fonts/ttf/DejaVuSans.ttf"), 26)
    for folder, row in picks:
        img = Image.open(CAMP / folder / "Tensiones.png").convert("RGB")
        img = img.crop((0, 0, 1500, 1060)).resize((750, 530))
        d = ImageDraw.Draw(img)
        if row is None:
            label = "m1=4 a1=100 m2=2 a2=100 b=40 e=4 mm  |  SEA 469.0 J/kg (optimum)"
        else:
            r = data.iloc[row]
            label = (f"m1={r.m1:.1f} a1={r.a1:.0f} m2={r.m2:.1f} a2={r.a2:.0f} b={r.b1:.0f} "
                     f"e={r.e_cartela:.1f} mm  |  SEA {r.energy_per_mass:.0f} J/kg")
        d.rectangle((0, 490, 750, 530), fill=(255, 255, 255))
        d.text((10, 495), label, fill=(20, 20, 20), font=ImageFont.truetype(font.path, 17))
        frames += [img] * 1
    frames[0].save(OUT / "gallery.gif", save_all=True, append_images=frames[1:], duration=1800, loop=0,
                   optimize=True)


def main():
    data, curves, opt = load()
    sea = data["energy_per_mass"].to_numpy()
    print(f"512 designs: mean SEA {sea.mean():.1f}, best {sea.max():.1f} (sim {sea.argmax() + 1})")
    fig_geometry()
    anim_gallery()
    for lang in TXT:
        fig_curves(data, curves, opt, lang)
        fig_hist(data, lang)
        anim_search(data, lang)
    for p in sorted(OUT.iterdir()):
        print(f"  {p.name}: {p.stat().st_size / 1e3:.0f} kB")


if __name__ == "__main__":
    main()
