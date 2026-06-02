#!/usr/bin/env python3
"""
build_field_data_from_kml.py

Ingest the Alderville sampling-design KML and produce the two field-data sheets
the pipeline expects (core_locations.csv, core_samples.csv).

WHAT THIS DOES
  1. Parses the KML sampling design:
       - 14 high-res ("regular") cores      -> Point geometries,   type hr_core
       - 24 composite plots                 -> Polygon geometries,  type composite
                                               (located at their centroid)
  2. Spatial-joins every site into Alderville_Restoration.geojson to read the
     restoration-age stratum from the `Restoratio` attribute
       (0_5 / 5_10 / 10_15 / 15_20 / Remnant).
  3. SYNTHESISES soil organic carbon (SOC) and bulk density (BD) depth profiles.
     The KML carries NO laboratory measurements, so these values are MOCK —
     realistic Ontario restored-prairie mineral-soil profiles for demoing the
     pipeline end to end. THEY ARE NOT REAL DATA and must not be reported.

DESIGN CHOICES (per project decisions, 2026-06)
  - core_id  = KML display name; composite ids are prefixed with their site
               (BOS-/PEM-) because the composite names repeat across the two
               sub-sites and must stay unique.
  - core_type = HR (high-res) | composite.
  - HR cores get fine 5 cm layers (0-100 cm); composites get the four IPCC
    intervals (0-15/15-30/30-60/60-100 cm) — coarse, as bulked composites are.

Stdlib only (no numpy/shapely) so it runs anywhere Python 3 is available.
Re-run to regenerate; outputs overwrite the placeholder sheets in data_raw/.
"""

import csv
import json
import math
import os
import random
import re
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_RAW = os.path.normpath(os.path.join(HERE, "..", "data_raw"))
KML_PATH = os.path.join(HERE, "Alderville_CarbonProject_SamplingSites.kml")
GEOJSON_PATH = os.path.join(DATA_RAW, "Alderville_Restoration.geojson")
LOC_OUT = os.path.join(DATA_RAW, "core_locations.csv")
SMP_OUT = os.path.join(DATA_RAW, "core_samples.csv")

KML_NS = "{http://www.opengis.net/kml/2.2}"
MONITORING_YEAR = 2026
SEED = 42

# ── Synthetic SOC / BD model parameters, by restoration-age stratum ──────────
# Older restoration / never-tilled remnant => more topsoil SOC, lower bulk density.
STRATA_ORDER = ["0_5", "5_10", "10_15", "15_20", "Remnant"]
SOC0 = {"0_5": 20.0, "5_10": 26.0, "10_15": 32.0, "15_20": 38.0, "Remnant": 50.0}  # g/kg at surface
BD0 = {"0_5": 1.28, "5_10": 1.20, "10_15": 1.12, "15_20": 1.05, "Remnant": 0.95}   # g/cm3 at surface
SOC_FLOOR = 1.5      # g/kg deep-soil floor
SOC_K = 0.040        # 1/cm exponential decline
BD_SLOPE = 0.0022    # g/cm3 per cm increase with depth

HR_LAYERS = [(d, d + 5) for d in range(0, 100, 5)]                 # 20 x 5 cm
COMPOSITE_LAYERS = [(0, 15), (15, 30), (30, 60), (60, 100)]        # IPCC intervals


# ── KML parsing ──────────────────────────────────────────────────────────────
def parse_description(desc):
    """Pull key/value attributes out of the Google-Earth HTML table description."""
    if not desc:
        return {}
    cells = re.findall(r"<td[^>]*>(.*?)</td>", desc, flags=re.S | re.I)
    cells = [re.sub(r"<[^>]*>", "", c).strip() for c in cells]
    cells = [c for c in cells if c != ""]
    # First cell is a header (the name/date); the rest are key, value pairs.
    body = cells[1:] if len(cells) % 2 == 1 else cells
    return {body[i]: body[i + 1] for i in range(0, len(body) - 1, 2)}


def site_of(folder_name):
    return "BOS" if folder_name.upper().startswith("BOS") else "PEM"


def collect_sites(kml_path):
    tree = ET.parse(kml_path)
    root = tree.getroot()
    doc = root.find(f"{KML_NS}Document")
    sites = []
    # Top-level folders carry the site (BOS/Pemadash) + group (composite/regular).
    for top in doc.findall(f"{KML_NS}Folder"):
        fname_el = top.find(f"{KML_NS}name")
        fname = fname_el.text if fname_el is not None else ""
        site = site_of(fname)
        for pm in top.iter(f"{KML_NS}Placemark"):
            name_el = pm.find(f"{KML_NS}name")
            desc_el = pm.find(f"{KML_NS}description")
            name = name_el.text if name_el is not None else ""
            attrs = parse_description(desc_el.text if desc_el is not None else "")
            is_point = pm.find(f".//{KML_NS}Point") is not None
            if is_point:
                lon = float(attrs.get("lon"))
                lat = float(attrs.get("lat"))
                core_type = "HR"
                core_id = name                      # already unique (BOS-R1, PEM-R1)
            else:
                lon = float(attrs.get("centroid_lon"))
                lat = float(attrs.get("centroid_lat"))
                core_type = "composite"
                core_id = f"{site}-{name}"           # disambiguate repeated COMP_* names
            sites.append({
                "core_id": core_id, "site": site, "core_type": core_type,
                "longitude": lon, "latitude": lat,
            })
    return sites


# ── Spatial join (ray casting, lon/lat) ──────────────────────────────────────
def point_in_ring(x, y, ring):
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if ((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def point_in_polygon(x, y, geom):
    polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
    for rings in polys:
        if point_in_ring(x, y, rings[0]) and not any(point_in_ring(x, y, h) for h in rings[1:]):
            return True
    return False


def ring_centroid(geom):
    polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
    pts = [pt for rings in polys for pt in rings[0]]
    return (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))


def assign_strata(sites, geojson_path):
    gj = json.load(open(geojson_path))
    feats = gj["features"]
    for s in sites:
        match = None
        for f in feats:
            if point_in_polygon(s["longitude"], s["latitude"], f["geometry"]):
                match = f["properties"].get("Restoratio")
                break
        if match is None:
            # Fallback: nearest polygon centroid (flagged), so no site is dropped.
            best, bestd = None, 1e18
            for f in feats:
                cx, cy = ring_centroid(f["geometry"])
                d = (cx - s["longitude"]) ** 2 + (cy - s["latitude"]) ** 2
                if d < bestd:
                    best, bestd = f["properties"].get("Restoratio"), d
            s["stratum"] = best
            s["stratum_source"] = "nearest"
        else:
            s["stratum"] = match
            s["stratum_source"] = "within"
    return sites


# ── Synthetic SOC / BD ───────────────────────────────────────────────────────
def soc_at(depth_mid, stratum, core_mult, rng):
    base = (SOC0[stratum] - SOC_FLOOR) * math.exp(-SOC_K * depth_mid) + SOC_FLOOR
    return max(0.1, base * core_mult * rng.gauss(1.0, 0.06))


def bd_at(depth_mid, stratum, rng):
    base = BD0[stratum] + BD_SLOPE * depth_mid
    return min(1.7, max(0.7, base * rng.gauss(1.0, 0.03)))


def make_samples(sites, rng):
    rows = []
    for s in sites:
        core_mult = rng.gauss(1.0, 0.08)               # per-core site effect
        layers = HR_LAYERS if s["core_type"] == "HR" else COMPOSITE_LAYERS
        for top, bot in layers:
            mid = (top + bot) / 2.0
            soc = soc_at(mid, s["stratum"], core_mult, rng)
            bd = bd_at(mid, s["stratum"], rng)
            rows.append({
                "core_id": s["core_id"],
                "depth_top_cm": top, "depth_bottom_cm": bot,
                "soc_g_kg": round(soc, 1), "bulk_density_g_cm3": round(bd, 2),
            })
    return rows


def main():
    rng = random.Random(SEED)
    sites = collect_sites(KML_PATH)
    sites = assign_strata(sites, GEOJSON_PATH)
    sites.sort(key=lambda s: (s["site"], s["core_type"], s["core_id"]))

    with open(LOC_OUT, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["core_id", "longitude", "latitude", "stratum", "monitoring_year", "core_type"])
        for s in sites:
            w.writerow([s["core_id"], round(s["longitude"], 7), round(s["latitude"], 7),
                        s["stratum"], MONITORING_YEAR, s["core_type"]])

    samples = make_samples(sites, rng)
    with open(SMP_OUT, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["core_id", "depth_top_cm", "depth_bottom_cm",
                                           "soc_g_kg", "bulk_density_g_cm3"])
        w.writeheader()
        w.writerows(samples)

    # ── Diagnostics ──────────────────────────────────────────────────────────
    from collections import Counter
    by_type = Counter(s["core_type"] for s in sites)
    by_stratum = Counter(s["stratum"] for s in sites)
    nearest = [s["core_id"] for s in sites if s["stratum_source"] == "nearest"]
    print(f"Parsed {len(sites)} sites: {dict(by_type)}")
    print(f"Strata (n cores): {dict(by_stratum)}")
    print(f"Samples written: {len(samples)} rows")
    if nearest:
        print(f"WARNING outside-all-polygons (assigned to nearest): {nearest}")
    else:
        print("All sites fell inside a restoration polygon.")
    print(f"Wrote {LOC_OUT}")
    print(f"Wrote {SMP_OUT}")


if __name__ == "__main__":
    main()
