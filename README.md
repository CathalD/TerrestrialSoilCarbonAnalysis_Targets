# Terrestrial Soil Carbon Analysis — targets Pipeline

Spatial prediction of soil organic carbon (SOC) stocks in terrestrial ecosystems
using transfer learning from global soil profile databases (WoSIS, CanPeat,
Agriculture Canada NSDB) and Google Earth Engine remote sensing covariates.

## Quick start

```r
# 1. Edit site configuration
# Edit soil_carbon_config.R — set PROJECT_NAME, VALID_STRATA, COVARIATE_RASTER

# 2. Place field data
# Pre-Analysis Data Preparation/data_raw/core_locations.csv
# Pre-Analysis Data Preparation/data_raw/core_samples.csv

# 3. Run main pipeline (data prep + harmonization + simple extrapolation)
targets::tar_make()

# 4. (Optional) Extract global GEE covariates
targets::tar_make(script = "_targets_preanalysis.R", store = "_targets_preanalysis")

# 5. (Optional) Transfer learning
targets::tar_make(script = "_targets_transfer.R", store = "_targets_transfer")
```

## Key outputs

- `reports/step1_nonspatial.html` — depth profiles, spatial map, stratum summaries
- `reports/step4_transfer_learning.html` — LOCO CV, similarity heatmap, prediction maps
- `outputs/transfer/tl_carbon_stocks_kg_m2.tif` — 4-band GeoTIFF per depth interval

## Depth intervals (IPCC Tier 2 aligned)

| Interval | Midpoint | Thickness |
|----------|----------|-----------|
| 0–15 cm  | 7.5 cm   | 15 cm     |
| 15–30 cm | 22.5 cm  | 15 cm     |
| 30–60 cm | 45 cm    | 30 cm     |
| 60–100 cm| 80 cm    | 40 cm     |

Aggregates to 0–30 cm (IPCC topsoil) and 0–100 cm (full profile).

## Documentation

See `CLAUDE.md` for full pipeline documentation, data sources, and
FAO SOC Mapping Cookbook workflow improvement recommendations.
