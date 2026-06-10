#!/usr/bin/env python3
"""
build_field_data_from_landcover.py

Ingest the James Bay Lowlands land-cover AOI + stratified-random sampling plots
and produce the field-data sheets (core_locations.csv, core_samples.csv).

INPUTS
  - data_raw/strata_map_aoi.geojson : a single AOI polygon. The per-stratum
      land-cover NAMES and AREAS live in the feature PROPERTIES
      (stratum_<code>_name / stratum_<code>_area_ha), derived from the
      ESRI 10 m 2024 land cover (ESA 6-class).
  - Sampling_Design/sampling_plot_locations_1.csv : stratified-random plots, each
      with a numeric land-cover `strata` code (2/4/6) and a GeoJSON `.geo` point.

WHAT IT DOES
  - Maps strata codes -> land-cover names (e.g. 2=Forest, 4=Herbaceous, 6=Wetland).
  - Writes core_locations.csv (one row per plot).
  - SYNTHESISES SOC + bulk-density depth profiles (NO lab data was provided):
    boreal mineral profiles for Forest/Herbaceous, organic (peat-like) for
    Wetland. MOCK data for demoing the pipeline only -- NOT real measurements.
  - Prints the per-stratum areas to paste into STRATUM_AREAS in the config.

Stdlib only. Re-run to regenerate; outputs overwrite the sheets in data_raw/.
"""
import csv
import json
import math
import os
import random
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_RAW = os.path.normpath(os.path.join(HERE, "..", "data_raw"))
AOI = os.path.join(DATA_RAW, "strata_map_aoi.geojson")
PLOTS = os.path.join(HERE, "sampling_plot_locations_1.csv")
LOC_OUT = os.path.join(DATA_RAW, "core_locations.csv")
SMP_OUT = os.path.join(DATA_RAW, "core_samples.csv")

MONITORING_YEAR = 2026
SEED = 42
LAYERS = [(0, 10), (10, 20), (20, 30), (30, 60), (60, 100)]  # cm

# Synthetic SOC/BD model per land-cover stratum. Forest/Herbaceous = mineral
# (SOC declines with depth); Wetland = organic peat (SOC high and ~flat, low BD).
PARAMS = {
    "Forest":     dict(soc0=45.0, k=0.030, soc_floor=6.0,   bd0=0.75, bd_slope=0.0045),
    "Herbaceous": dict(soc0=30.0, k=0.028, soc_floor=5.0,   bd0=1.00, bd_slope=0.0040),
    "Wetland":    dict(soc0=460.0, k=0.004, soc_floor=300.0, bd0=0.12, bd_slope=0.0006),
}


def stratum_lookup(aoi_path):
    g = json.load(open(aoi_path))
    props = g["features"][0]["properties"]
    names, areas = {}, {}
    for k, v in props.items():
        parts = k.split("_")
        if k.startswith("stratum_") and k.endswith("_name"):
            names[int(parts[1])] = v
        elif k.startswith("stratum_") and k.endswith("_area_ha"):
            areas[int(parts[1])] = float(v)
    return names, areas


def read_plots(csv_path):
    rows = []
    with open(csv_path, newline="") as fh:
        for r in csv.DictReader(fh):
            geo = json.loads(r[".geo"])
            lon, lat = geo["coordinates"][0], geo["coordinates"][1]
            rows.append(dict(idx=int(r["system:index"]), code=int(r["strata"]),
                             lon=lon, lat=lat))
    return rows


def soc_at(mid, p, mult, rng):
    base = (p["soc0"] - p["soc_floor"]) * math.exp(-p["k"] * mid) + p["soc_floor"]
    # Cap at ~55% C (550 g/kg) — physical upper limit for soil organic matter.
    return min(550.0, max(0.1, base * mult * rng.gauss(1.0, 0.06)))


def bd_at(mid, p, rng):
    return min(1.8, max(0.03, (p["bd0"] + p["bd_slope"] * mid) * rng.gauss(1.0, 0.03)))


def main():
    rng = random.Random(SEED)
    names, areas = stratum_lookup(AOI)
    plots = sorted(read_plots(PLOTS), key=lambda x: x["idx"])

    locs, samples = [], []
    for pl in plots:
        name = names.get(pl["code"], "code%d" % pl["code"])
        cid = "SP%02d" % pl["idx"]
        locs.append((cid, round(pl["lon"], 7), round(pl["lat"], 7), name))
        p = PARAMS.get(name, PARAMS["Forest"])
        mult = rng.gauss(1.0, 0.08)
        for top, bot in LAYERS:
            mid = (top + bot) / 2.0
            samples.append((cid, top, bot,
                            round(soc_at(mid, p, mult, rng), 1),
                            round(bd_at(mid, p, rng), 2)))

    with open(LOC_OUT, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["core_id", "longitude", "latitude", "stratum",
                    "monitoring_year", "core_type"])
        for cid, lon, lat, name in locs:
            w.writerow([cid, lon, lat, name, MONITORING_YEAR, "stratified_random"])

    with open(SMP_OUT, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["core_id", "depth_top_cm", "depth_bottom_cm",
                    "soc_g_kg", "bulk_density_g_cm3"])
        w.writerows(samples)

    by = Counter(name for _, _, _, name in locs)
    print("Plots: %d  %s" % (len(locs), dict(by)))
    print("Sample rows: %d" % len(samples))
    print("Strata (code -> name): %s" % names)
    print("STRATUM_AREAS (ha):     %s" % {names[c]: areas[c] for c in sorted(names)})
    print("Wrote %s" % LOC_OUT)
    print("Wrote %s" % SMP_OUT)


if __name__ == "__main__":
    main()
