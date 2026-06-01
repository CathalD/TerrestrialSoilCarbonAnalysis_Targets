# Terrestrial Soil Carbon Analysis — User Guide

## What this pipeline does

Takes field soil core data → harmonizes depths → extracts remote sensing covariates
→ predicts soil organic carbon (SOC) stocks spatially → estimates 90% uncertainty.

Depth intervals follow IPCC Tier 2 standards:

| Interval | Midpoint | Thickness |
|----------|----------|-----------|
| 0–15 cm  | 7.5 cm   | 15 cm     |
| 15–30 cm | 22.5 cm  | 15 cm     |
| 30–60 cm | 45 cm    | 30 cm     |
| 60–100 cm| 80 cm    | 40 cm     |

---

## Step 1 — Configure the project

Edit `soil_carbon_config.R` in the project root:

```r
PROJECT_NAME    <- "MySite_2025"
PROJECT_LOCATION <- "Central Alberta, Canada"
MONITORING_YEAR  <- 2025

# Stratum codes — must match your core_locations.csv
VALID_STRATA <- c("F", "GL", "CL")
# Common codes: F = Forest, GL = Grassland, CL = Cropland, PL = Peatland

# Path to your 28-band GEE covariate raster (required for RF maps)
COVARIATE_RASTER <- "Pre-Analysis Data Preparation/covariates/your_raster.tif"
```

**Bulk density defaults** (used where `bulk_density_g_cm3` is missing):

| Code | Ecosystem | Default BD |
|------|-----------|-----------|
| F    | Forest    | 0.90 g/cm³ |
| GL   | Grassland | 1.20 g/cm³ |
| CL   | Cropland  | 1.30 g/cm³ |
| PL   | Peatland  | 0.15 g/cm³ |

Add or adjust these in the `BD_DEFAULTS` list in `soil_carbon_config.R`.

---

## Step 2 — Prepare your field data

Place two CSV files in:
```
Pre-Analysis Data Preparation/data_raw/
```

### core_locations.csv

One row per soil core.

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `core_id` | text | ✓ | Unique ID — no spaces |
| `longitude` | numeric | ✓ | WGS84 decimal degrees |
| `latitude` | numeric | ✓ | WGS84 decimal degrees |
| `stratum` | text | ✓ | Must match `VALID_STRATA` |
| `monitoring_year` | integer | optional | Year of sampling |

Example:
```csv
core_id,longitude,latitude,stratum,monitoring_year
TSOF1,-115.2,53.5,F,2024
TSOGL1,-112.4,51.2,GL,2024
TSOCL1,-110.8,50.9,CL,2024
```

### core_samples.csv

One row per soil layer within each core.

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `core_id` | text | ✓ | Must match `core_locations.csv` |
| `depth_top_cm` | numeric | ✓ | Top depth of the layer (cm) |
| `depth_bottom_cm` | numeric | ✓ | Bottom depth of the layer (cm) |
| `soc_g_kg` | numeric | ✓ | Soil organic carbon (g SOC per kg soil) |
| `bulk_density_g_cm3` | numeric | optional | If missing, stratum default is used |

Example:
```csv
core_id,depth_top_cm,depth_bottom_cm,soc_g_kg,bulk_density_g_cm3
TSOF1,0,5,28.3,0.85
TSOF1,5,15,22.1,0.92
TSOF1,15,30,15.8,1.05
TSOF1,30,60,9.4,1.18
TSOF1,60,100,5.2,1.25
```

**Minimum data requirements:**
- At least 3 complete cores per stratum for the RF model to train.
- Aim for 15–30 cores per stratum for reliable spatial prediction.
- Cores should span the depth range 0–100 cm where possible (not mandatory — the equal-area spline will extrapolate).

---

## Step 3 — Run the basic analysis (no GEE needed)

Open RStudio in the project root and run:

```r
targets::tar_make()
```

**What this produces:**
- `reports/step1_nonspatial.html` — depth profiles, stratum summaries, exploratory plots
- `_targets/` store with harmonized core data

**Runtime:** 2–10 minutes depending on number of cores.

---

## Step 4 — Run the RF spatial maps (requires covariate raster)

You need a 28-band GEE raster covering your site (see Step 6 for how to export it).
Set `COVARIATE_RASTER` in `soil_carbon_config.R` then run:

```r
targets::tar_make(script = "_targets_rf.R", store = "_targets_rf")
```

**What this produces:**
- `reports/step3_random_forest.html` — variable importance, per-depth maps, total stock map
- `_targets_rf/` store with model objects and rasters

**Runtime:** 5–15 minutes.

---

## Step 5 — Export the site covariate raster from GEE

Open `Pre-Analysis Data Preparation/GEE_Python/GoogleEarthEngineAOICovariateAnalysis.js`
in the [Google Earth Engine Code Editor](https://code.earthengine.google.com).

1. **Set your AOI** — edit the geometry at the top of Section A to cover your site.
2. **Set your GEE project** — update `var project = 'your-project-id'` in Section A.
3. **Run Sections A–D** to preview the 28-band stack.
4. **Run Section E — Export** to send the raster to your Google Drive.
5. Download the `.tif` from Drive and place it in:
   ```
   Pre-Analysis Data Preparation/covariates/
   ```
6. Update `COVARIATE_RASTER` in `soil_carbon_config.R` to point to the downloaded file.

**The 28-band stack includes:**

| Group | Bands |
|-------|-------|
| Topography (6) | elevation, slope, aspect, TWI, TPI, curvature |
| SAR / Sentinel-1 (3) | VV, VH, VV/VH ratio |
| Optical / Sentinel-2 (9) | B, G, R, B5, B6, B7, NIR, SWIR1, SWIR2 |
| Spectral indices (6) | NDVI, EVI, LSWI, SAVI, NDMI, BSI |
| Climate / TerraClimate (4) | MAT, MAP, PET, aridity index |

---

## Step 6 — Transfer learning with global soil databases (optional)

Transfer learning improves predictions when you have few local cores (< 15) by
borrowing from global databases (WoSIS, CanPeat, Agriculture Canada).

### 6a. Prepare the global database files

Download and place in `Pre-Analysis Data Preparation/data_global/`:

| File | Source | Script to prepare |
|------|--------|-------------------|
| `wosis_layers.csv` | [WoSIS 2023](https://www.isric.org/explore/wosis) | `R_Scripts/01_WOSIS_harmonize.R` |
| `canpeat_layers.csv` | [CanPeat](https://doi.org/10.5194/essd-13-3945-2021) | `R_Scripts/02_Peat_harmonize.R` |
| `agricanada_nsdb_layers.csv` | [AgriCanada NSDB](https://open.canada.ca/data) | manual (see column format below) |

All three files must have these columns:
`dataset, profile_id, layer_id, latitude, longitude, upper_depth, lower_depth, layer_thickness_cm, BDOD, OrgC_pct, year`

### 6b. Authenticate GEE (one time only)

```r
library(rgee)
ee_Initialize(user = "your.email@gmail.com", drive = TRUE)
```

### 6c. Run the pre-analysis pipeline

```r
targets::tar_make(
  script = "_targets_preanalysis.R",
  store  = "_targets_preanalysis"
)
```

This extracts 28 GEE covariates at all global profile locations and writes:
- `data_global/combined_layers_filtered.csv` — global SOC profile data
- `data_raw/TerrestrialSOC_GlobalCorePoints_Covariates.csv` — GEE covariates

**Runtime:** ~60 minutes (GEE API calls).

### 6d. Run transfer learning (Wadoux method)

```r
targets::tar_make(
  script = "_targets_transfer.R",
  store  = "_targets_transfer"
)
```

**What this produces:**
- `reports/step4_transfer_learning.html` — bias, CV metrics, similarity heatmap, maps
- `outputs/transfer/tl_carbon_stocks_kg_m2.tif` — 4-band GeoTIFF per depth interval

**Runtime:** ~15 minutes.

### 6e. Run transfer learning (Embedding method, optional)

```r
targets::tar_make(
  script = "_targets_embedding.R",
  store  = "_targets_embedding"
)
```

**What this produces:**
- `reports/step5_embedding_tl.html` — comparison with Wadoux method

**Runtime:** ~30 minutes.

---

## Output raster format

The transfer learning rasters (`outputs/transfer/tl_carbon_stocks_kg_m2.tif`)
are multi-band GeoTIFFs. Each depth interval contributes 4 bands:

| Band name | Description |
|-----------|-------------|
| `dX_Global_Prior` | Wadoux-weighted RF prediction (no local correction) |
| `dX_Transfer_Final` | Bias-corrected prediction **(use this)** |
| `dX_Local_Only` | Constant = mean of local cores (naive baseline) |
| `dX_Difference` | Transfer Final minus Local Only |

`X` = depth midpoint (e.g. `d7_5` for the 0–15 cm interval).

---

## Troubleshooting

**Pipeline errored:**
```r
targets::tar_meta() |>
  dplyr::filter(!is.na(error)) |>
  dplyr::select(name, error)
```

**Re-run a single target:**
```r
targets::tar_make(names = "cores_harmonized")
```

**Strata mismatch error:**
Check that the values in the `stratum` column of `core_locations.csv` exactly
match the `VALID_STRATA` vector in `soil_carbon_config.R` (case-sensitive).

**Bulk density all missing:**
Ensure `BD_DEFAULTS` in `soil_carbon_config.R` has an entry for every stratum code
in your data — missing entries cause `NA` carbon stocks.

**GEE authentication fails:**
Re-run `ee_Initialize()`. Make sure you have the `rgee` package installed and
have enabled the Earth Engine API for your Google Cloud project.
