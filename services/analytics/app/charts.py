"""
SVG chart generators
---------------------
Hand-rolled SVG so charts export cleanly as vectors (deck-ready) and inherit
the dashboard's light/dark theme via currentColor + CSS variables. No chart lib.
All functions return an SVG string.
"""
from html import escape

# IBM-ish palette; accent is IBM blue
PALETTE = ["#0f62fe", "#42be65", "#ff832b", "#8a3ffc", "#ee5396",
           "#08bdba", "#fa4d56", "#4589ff", "#d2a106", "#6fdc8c"]


def _txt(x, y, s, size=12, anchor="start", weight="400", fill="currentColor", opacity="1"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" '
            f'text-anchor="{anchor}" font-weight="{weight}" fill="{fill}" '
            f'opacity="{opacity}" font-family="IBM Plex Sans, system-ui, sans-serif">'
            f'{escape(str(s))}</text>')


def bar_chart(labels, values, width=520, height=300, title="", value_prefix=""):
    pad_l, pad_r, pad_t, pad_b = 60, 20, 40 if title else 16, 60
    pw, ph = width - pad_l - pad_r, height - pad_t - pad_b
    vmax = max(values) if values and max(values) > 0 else 1
    n = len(values) or 1
    gap = 12
    bw = max((pw - gap * (n - 1)) / n, 4)

    parts = [f'<svg viewBox="0 0 {width} {height}" xmlns="http://www.w3.org/2000/svg" '
             f'role="img" class="gsp-chart">']
    if title:
        parts.append(_txt(pad_l, 22, title, size=14, weight="600"))
    # gridlines
    for i in range(5):
        gy = pad_t + ph * i / 4
        val = vmax * (1 - i / 4)
        parts.append(f'<line x1="{pad_l}" y1="{gy:.1f}" x2="{width-pad_r}" y2="{gy:.1f}" '
                     f'stroke="currentColor" stroke-opacity="0.12"/>')
        parts.append(_txt(pad_l - 8, gy + 4, f"{value_prefix}{val:,.0f}", size=10,
                          anchor="end", opacity="0.6"))
    # bars
    for i, (lab, val) in enumerate(zip(labels, values)):
        bh = ph * (val / vmax)
        x = pad_l + i * (bw + gap)
        y = pad_t + ph - bh
        color = PALETTE[i % len(PALETTE)]
        parts.append(f'<rect x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{bh:.1f}" '
                     f'rx="2" fill="{color}"><title>{escape(str(lab))}: {value_prefix}{val:,.0f}</title></rect>')
        short = (str(lab)[:10] + "…") if len(str(lab)) > 11 else str(lab)
        parts.append(_txt(x + bw / 2, height - pad_b + 16, short, size=10,
                          anchor="middle", opacity="0.75"))
    parts.append('</svg>')
    return "".join(parts)


def line_chart(labels, series, width=620, height=300, title="", value_prefix=""):
    """series: list of dicts {name, values, color?}"""
    pad_l, pad_r, pad_t, pad_b = 60, 20, 44 if title else 20, 50
    pw, ph = width - pad_l - pad_r, height - pad_t - pad_b
    all_vals = [v for s in series for v in s["values"]] or [0, 1]
    vmax = max(all_vals) or 1
    vmin = min(all_vals + [0])
    span = (vmax - vmin) or 1
    n = max(len(labels), 1)

    def px(i):
        return pad_l + (pw * i / max(n - 1, 1))

    def py(v):
        return pad_t + ph - ph * (v - vmin) / span

    parts = [f'<svg viewBox="0 0 {width} {height}" xmlns="http://www.w3.org/2000/svg" '
             f'role="img" class="gsp-chart">']
    if title:
        parts.append(_txt(pad_l, 24, title, size=14, weight="600"))
    for i in range(5):
        gy = pad_t + ph * i / 4
        val = vmax - span * i / 4
        parts.append(f'<line x1="{pad_l}" y1="{gy:.1f}" x2="{width-pad_r}" y2="{gy:.1f}" '
                     f'stroke="currentColor" stroke-opacity="0.12"/>')
        parts.append(_txt(pad_l - 8, gy + 4, f"{value_prefix}{val:,.0f}", size=10,
                          anchor="end", opacity="0.6"))
    # x labels (sparse)
    step = max(n // 6, 1)
    for i in range(0, n, step):
        parts.append(_txt(px(i), height - pad_b + 16, labels[i], size=9,
                          anchor="middle", opacity="0.6"))
    for si, s in enumerate(series):
        color = s.get("color", PALETTE[si % len(PALETTE)])
        pts = " ".join(f"{px(i):.1f},{py(v):.1f}" for i, v in enumerate(s["values"]))
        parts.append(f'<polyline points="{pts}" fill="none" stroke="{color}" '
                     f'stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>')
        # legend
        ly = pad_t + 4 + si * 16
        parts.append(f'<rect x="{width-pad_r-110}" y="{ly-9}" width="10" height="10" rx="2" fill="{color}"/>')
        parts.append(_txt(width - pad_r - 95, ly, s["name"], size=10, opacity="0.8"))
    parts.append('</svg>')
    return "".join(parts)


def donut_chart(labels, values, width=300, height=300, title=""):
    import math
    cx, cy, r, rin = width / 2, height / 2 + (10 if title else 0), 95, 55
    total = sum(values) or 1
    parts = [f'<svg viewBox="0 0 {width} {height}" xmlns="http://www.w3.org/2000/svg" '
             f'role="img" class="gsp-chart">']
    if title:
        parts.append(_txt(width / 2, 22, title, size=14, weight="600", anchor="middle"))
    angle = -math.pi / 2
    for i, (lab, val) in enumerate(zip(labels, values)):
        frac = val / total
        a2 = angle + frac * 2 * math.pi
        large = 1 if frac > 0.5 else 0
        x1, y1 = cx + r * math.cos(angle), cy + r * math.sin(angle)
        x2, y2 = cx + r * math.cos(a2), cy + r * math.sin(a2)
        xi1, yi1 = cx + rin * math.cos(a2), cy + rin * math.sin(a2)
        xi2, yi2 = cx + rin * math.cos(angle), cy + rin * math.sin(angle)
        color = PALETTE[i % len(PALETTE)]
        d = (f"M {x1:.1f} {y1:.1f} A {r} {r} 0 {large} 1 {x2:.1f} {y2:.1f} "
             f"L {xi1:.1f} {yi1:.1f} A {rin} {rin} 0 {large} 0 {xi2:.1f} {yi2:.1f} Z")
        parts.append(f'<path d="{d}" fill="{color}"><title>{escape(str(lab))}: {val:,.0f} ({frac*100:.1f}%)</title></path>')
        angle = a2
    parts.append('</svg>')
    return "".join(parts)
