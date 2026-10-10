"""Route preparation: simplify, smooth, resample, fit. Pure python, no basemap."""
from __future__ import annotations

import math


def _project(points):
    """(lat, lon) pairs -> local x/y (north up). Pass through if already x/y-like."""
    lat0 = sum(p[0] for p in points) / len(points)
    k = math.cos(math.radians(lat0))
    return [(p[1] * k, -p[0]) for p in points]


def _dp(pts, eps):
    if len(pts) < 3:
        return list(pts)
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        a, b = stack.pop()
        ax, ay = pts[a]
        bx, by = pts[b]
        dx, dy = bx - ax, by - ay
        norm = math.hypot(dx, dy)
        best, bi = -1.0, -1
        for i in range(a + 1, b):
            if norm < 1e-12:  # closed loop: chord is a point
                d = math.hypot(pts[i][0] - ax, pts[i][1] - ay)
            else:
                d = abs(dy * (pts[i][0] - ax) - dx * (pts[i][1] - ay)) / norm
            if d > best:
                best, bi = d, i
        if best > eps:
            keep[bi] = True
            stack += [(a, bi), (bi, b)]
    return [p for p, k in zip(pts, keep) if k]


def _catmull(pts, per=12):
    out = []
    n = len(pts)
    for i in range(n - 1):
        p0 = pts[max(i - 1, 0)]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[min(i + 2, n - 1)]
        for s in range(per):
            t = s / per
            t2, t3 = t * t, t * t * t
            out.append(
                tuple(
                    0.5 * (2 * p1[c] + (-p0[c] + p2[c]) * t + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2
                           + (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t3)
                    for c in (0, 1)
                )
            )
    out.append(pts[-1])
    return out


def _resample(pts, n):
    cum = [0.0]
    for a, b in zip(pts, pts[1:]):
        cum.append(cum[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    total = cum[-1] or 1e-12
    out, j = [], 0
    for i in range(n):
        d = total * i / (n - 1)
        while j < len(cum) - 2 and cum[j + 1] < d:
            j += 1
        seg = (cum[j + 1] - cum[j]) or 1e-12
        f = (d - cum[j]) / seg
        out.append((pts[j][0] + (pts[j + 1][0] - pts[j][0]) * f, pts[j][1] + (pts[j + 1][1] - pts[j][1]) * f))
    return out


def prepare_route(points, n: int = 600, latlon: bool = True):
    """Simplified, smoothed, uniformly spaced polyline (unit-free x/y)."""
    if len(points) < 2:
        raise ValueError("route needs at least 2 points")
    xy = _project(points) if latlon else [tuple(p) for p in points]
    xs, ys = [p[0] for p in xy], [p[1] for p in xy]
    diag = math.hypot(max(xs) - min(xs), max(ys) - min(ys)) or 1e-9
    simp = _dp(xy, diag * 0.004)
    if len(simp) > 2:
        simp = _catmull(simp)
    return _resample(simp, n)


def fit(pts, box):
    """Scale and centre pts into box (x0, y0, x1, y1) keeping aspect."""
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    w, h = (x1 - x0) or 1e-9, (y1 - y0) or 1e-9
    bx0, by0, bx1, by1 = box
    s = min((bx1 - bx0) / w, (by1 - by0) / h)
    ox = bx0 + ((bx1 - bx0) - w * s) / 2
    oy = by0 + ((by1 - by0) - h * s) / 2
    return [(ox + (x - x0) * s, oy + (y - y0) * s) for x, y in pts]


def head(pts, frac):
    """Points up to arclength fraction frac (0..1), ending on an interpolated point."""
    n = len(pts)
    f = max(0.0, min(1.0, frac)) * (n - 1)
    i = int(f)
    if i >= n - 1:
        return list(pts)
    r = f - i
    a, b = pts[i], pts[i + 1]
    return list(pts[: i + 1]) + [(a[0] + (b[0] - a[0]) * r, a[1] + (b[1] - a[1]) * r)]
