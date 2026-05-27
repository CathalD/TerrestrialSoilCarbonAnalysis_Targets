# Terrestrial Soil Carbon Analysis — Project Guide

## What this project does

Spatial prediction of soil organic carbon (SOC) stocks in terrestrial ecosystems
(forest, grassland, cropland, peatland) for carbon accounting and monitoring.

The pipeline takes field soil cores → harmonizes depths → extracts remote sensing
covariates globally and locally → predicts stocks across a full site raster →
estimates uncertainty at 90% confidence.

Depth reporting aligns with IPCC Tier 2 standards: 0–30 cm (topsoil) and
0–100 cm (full mineral profile).

---

## Tech stack

| Tool | Role |
|------|------|
| `targets` + `tarchetypes` + `geotargets` | Reproducible pipeline orchestration |
| `terra` + `sf` | Raster and vector spatial operations |
| `rgee` | R interface to Google Earth Engine |
| `ranger` | Random forest (transfer learning — supports case weights) |
| `randomForest` | Random forest (main RF pipeline) |
| `dplyr` / `tidyr` / `readr` | Data wrangling |
| `ggplot2` | All plots |
| Quarto (HTML) | Reports |

---

## Repository layout

```
BlueCarbonAnalysis_Targets-main/
├── _targets.R                    # Main pipeline (Steps 1–3)
├── _targets_transfer.R           # Transfer learning pipeline (Step 4 — Wadoux)
├── _targets_preanalysis.R        # Pre-analysis: global GEE covariate extraction
├── _targets_embedding.R          # Embedding TL pipeline (Step 5 — Model 2)
├── _targets.yaml                 # Named configs: main / transfer / preanalysis / embedding
├── soil_carbon_config.R          # Site-specific settings (edit per project)
├── R/                            # One .R file per analysis step
│   ├── config.R                  # load_config() — wraps soil_carbon_config.R
│   ├── data_prep.R               # load_raw_data()
│   ├── depth_harmonization.R     # harmonize_depths(), fit_hybrid_profile()
│   ├── exploratory_analysis.R    # run_eda()
│   ├── random_forest.R           # prepare_rf_data(), train_rf(), predict_rf_rasters()
│   ├── simple_extrapolation.R    # simple_extrapolation()
│   ├── summarise.R               # summarise_strata()
│   ├── transfer_learning.R       # harmonize_global_layers(), prepare_tl_data(),
│   │                             # train_tl(), predict_tl_rasters(), plot_tl_maps()
│   ├── preanalysis/              # GEE extraction modules
│   │   ├── global_data.R         # ingest_wosis(), ingest_canpeat(),
│   │   │                         # ingest_agricanada(), combine_global_profiles(),
│   │   │                         # filter_for_gee()
│   │   ├── gee_covariates.R      # extract_*(). combine_covariates(), write_covariates_csv()
│   │   └── gee_setup.R           # initialize_gee()
│   └── embedding_tl/             # Foundation model similarity modules
│       ├── gee_embeddings.R
│       ├── embedding_similarity.R
│       └── embedding_tl_model.R
├── reports/
│   ├── step1_nonspatial.qmd
│   ├── step3_random_forest.qmd
│   ├── step4_transfer_learning.qmd
│   └── step5_embedding_tl.qmd
├── Pre-Analysis Data Preparation/
│   ├── data_raw/                 # Local field data + GEE exports
│   │   ├── core_locations.csv    # core_id, latitude, longitude, stratum
│   │   ├── core_samples.csv      # core_id, depth_cm, soc_g_kg, bulk_density_g_cm3
│   │   └── TerrestrialSOC_GlobalCorePoints_Covariates.csv  # written by preanalysis pipeline
│   ├── data_global/              # Global soil profile databases
│   │   ├── wosis_layers.csv      # WoSIS 2023 (output of 01_WOSIS_harmonize.R)
│   │   ├── canpeat_layers.csv    # CanPeat Canadian peatland data
│   │   ├── agricanada_nsdb_layers.csv  # Agriculture Canada NSDB
│   │   └── combined_layers_filtered.csv  # written by preanalysis pipeline
│   ├── covariates/
│   │   └── TerrestrialSOC_Covariate_Snapshot_25m_2020_2023.tif  # 28-band GEE export
│   ├── R_Scripts/                # Pre-analysis data harmonization (run once)
│   │   ├── 01_WOSIS_harmonize.R  # WoSIS 2023 → wosis_layers.csv
│   │   └── 02_Peat_harmonize.R   # CanPeat → canpeat_layers.csv
│   └── GEE_Python/
│       └── GoogleEarthEngineAOICovariateAnalysis.js   # AOI covariate extraction (JS)
└── outputs/
    ├── rf/
    ├── transfer/
    └── embedding/
```

---

## Pipeline steps

### Run order

```r
1. tar_make()                                          # Steps 1–2: data prep + simple extrapolation
2. tar_make(script="_targets_rf.R",                    # Step 3: RF spatial maps (needs covariate raster)
            store="_targets_rf")
3. tar_make(script="_targets_preanalysis.R",           # Pre-analysis: global GEE extraction
            store="_targets_preanalysis")
4. tar_make(script="_targets_transfer.R",              # Step 4: Wadoux transfer learning
            store="_targets_transfer")
5. tar_make(script="_targets_embedding.R",             # Step 5: Embedding transfer learning
            store="_targets_embedding")
```

Steps 4 and 5 require Step 3 to have run first — they read `combined_layers_filtered.csv`
and `TerrestrialSOC_GlobalCorePoints_Covariates.csv` written by the preanalysis pipeline.

---

### Main pipeline (`_targets.R`)

| Step | Key targets | What it produces |
|------|-------------|------------------|
| 1 — Data prep | `cores_raw`, `eda_plots`, `cores_harmonized` | Depth-harmonized field cores |
| 2 — Simple extrapolation | `step2_extrapolation` | Per-stratum carbon densities (no raster) |
| Reports | `report_nonspatial` | `reports/step1_nonspatial.html` |

### RF pipeline (`_targets_rf.R`)

| Step | Key targets | What it produces |
|------|-------------|------------------|
| 3 — Random forest | `rf_data`, `rf_models`, `rf_rasters`, `rf_maps` | Spatial carbon stock maps |
| Reports | `report_rf` | `reports/step3_random_forest.html` |

---

### Pre-analysis pipeline (`_targets_preanalysis.R`)

Extracts a canonical 28-band terrestrial covariate stack at all global soil
profile locations via Google Earth Engine. Output feeds both TL pipelines.

**Global databases:**

| Database | File | Description |
|----------|------|-------------|
| WoSIS 2023 | `wosis_layers.csv` | ISRIC World Soil Information Service; global coverage |
| CanPeat | `canpeat_layers.csv` | Canadian peatland carbon (Packalen & Bhatti 2021) |
| AgriCanada NSDB | `agricanada_nsdb_layers.csv` | Agriculture Canada National Soil DataBase |

**Canonical 28 bands:**
- Topography (6): `elevation_m`, `slope`, `aspect`, `twi`, `tpi`, `curvature`
- SAR (3): `VV_mean`, `VH_mean`, `VVVH_ratio`
- S2 optical (9): `B`, `G`, `R`, `B5`, `B6`, `B7`, `NIR`, `SWIR1`, `SWIR2`
- S2 derived (6): `NDVI_median`, `EVI_median`, `LSWI_median`, `SAVI_median`, `NDMI_median`, `BSI_median`
- Climate (4): `MAT_C`, `MAP_mm`, `PET_mm`, `aridity_index`

---

### Transfer learning pipeline — Model 1 (`_targets_transfer.R`)

Wadoux instance weighting: domain classifier RF estimates how similar each global
profile is to the local site; weighted global RF is trained and bias-corrected.

**Bridge variables (reduced — N_local < 15):**
`NDVI_median`, `EVI_median`, `LSWI_median`, `VV_mean`, `twi`, `MAT_C`, `MAP_mm`

**Bridge variables (full — N_local ≥ 15):**
Above plus `elevation_m`, `slope`, `aspect`, `tpi`, `VH_mean`, `VVVH_ratio`,
`B`, `G`, `R`, `NIR`, `SWIR1`, `SWIR2`, `SAVI_median`, `NDMI_median`

---

### Embedding transfer learning pipeline — Model 2 (`_targets_embedding.R`)

Replaces the Wadoux domain classifier with cosine similarity in the 64-d space
of `GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL`. Stages B–D identical to Model 1.

---

## Standard depth intervals — must not change without project review

```r
DEPTH_MIDPOINTS <- c(7.5, 22.5, 45, 80)   # cm

DEPTH_INTERVALS:
  0–15 cm   (midpoint 7.5,  thickness 15 cm)
  15–30 cm  (midpoint 22.5, thickness 15 cm)
  30–60 cm  (midpoint 45,   thickness 30 cm)
  60–100 cm (midpoint 80,   thickness 40 cm)

Carbon stock formula:
  carbon_stock_kg_m2 = SOC(g/kg) × BD(g/cm³) × thickness(cm) / 100

Standard aggregates:
  0–30 cm  = sum of depth intervals 1 + 2  (IPCC Tier 2 topsoil)
  0–100 cm = sum of all 4 depth intervals   (IPCC full profile)

Uncertainty: 90% prediction intervals (conservative reporting bound)
CV strategy: leave-one-CORE-out (not leave-one-observation-out)
```

Always read from `cfg$DEPTH_MIDPOINTS` — never hardcode.

---

## Config values to know

```r
cfg$PROJECT_NAME
cfg$DEPTH_MIDPOINTS          # c(7.5, 22.5, 45, 80)
cfg$DEPTH_INTERVALS          # data.frame with depth_top/bottom/midpoint/thickness_cm
cfg$BD_DEFAULTS              # list(F=0.90, GL=1.20, CL=1.30) g/cm³
cfg$VALID_STRATA             # c("F", "GL", "CL")
cfg$COVARIATE_RASTER         # path to local GEE raster (28-band)
cfg$DATA_GLOBAL_DIR          # "Pre-Analysis Data Preparation/data_global"
cfg$BAND_LABELS              # named vector: raster band name → human-readable label
```

---

## FAO SOC Mapping Cookbook — recommended workflow improvements

Based on the FAO/ITPS SOC Mapping Cookbook (2nd ed., 2019) and related digital
soil mapping (DSM) literature, the following enhancements are recommended:

### Additional covariates (high priority)
| Covariate | Source | Rationale |
|-----------|--------|-----------|
| Clay content 0–30 cm | SoilGrids v2 | Organo-mineral stabilisation — one of the strongest global SOC predictors |
| Land cover class | ESA WorldCover 10m / MODIS LC | Land use is the dominant control on SOC under human management |
| NDVI seasonality (StdDev) | Sentinel-2 annual series | Temporal variability separates perennial vs. seasonal vegetation |
| Lithology | GLiM v1.0 (Hartmann & Moosdorf 2012) | Parent material controls mineralogy and long-term SOC storage |
| Snow cover days | MODIS MOD10A1 | Freeze-thaw cycling affects decomposition; important for boreal sites |

### Spatial cross-validation (recommended upgrade)
LOCO CV is unbiased but ignores spatial autocorrelation. Replace with:
- **Geographic k-fold blocking** (Valavi et al. 2019, `blockCV` R package)
- Block size ≈ variogram range of residuals (typically 10–50 km for SOC)
- This gives realistic estimates of prediction error at unsampled locations.

### Separate models by land use
RF trained on mixed land uses often underperforms for individual classes.
Consider stratifying the global training data or fitting depth-land-use models:
- Peatland SOC follows a different depth profile (flat, very high) vs. mineral soil
- Cropland SOC is typically lower and more uniform with depth than forest

### SoilGrids SOC as model covariate (not just as prior for sampling)
SoilGrids v2.0 SOC is available at 250 m. Export it as an additional raster band
(already in the GEE JS step 2 optional output) and include in the RF feature set.
This provides a global-scale spatial prior that the local bias correction can refine.

### Quantile Regression Forest (QRF)
Replace `ranger(...)` with `ranger(quantreg = TRUE)` to get full predictive
distribution at each pixel without the bootstrap bias-correction step. QRF
provides theoretically sound prediction intervals.

---

## Code conventions

### Adding a new global database
1. Write `ingest_xyz()` in `R/preanalysis/global_data.R`
   - Must return `list(layers = <data.frame>, source = "xyz")`
   - layers must have: `dataset`, `profile_id`, `layer_id`, `latitude`, `longitude`,
     `upper_depth`, `lower_depth`, `layer_thickness_cm`, `BDOD`, `OrgC_pct`, `year`
2. Add `tar_target(xyz_data, ingest_xyz(xyz_file))` to `_targets_preanalysis.R`
3. Add `xyz_data` to the `combine_global_profiles(...)` call

### Adding a new GEE covariate band
1. Add the band to `CANONICAL_BANDS` in `R/preanalysis/gee_covariates.R`
2. Update the corresponding `.build_*_stack()` function
3. Update `GoogleEarthEngineAOICovariateAnalysis.js` Section C and the band manifest
4. Update `BAND_LABELS` in `soil_carbon_config.R`
5. Update `_BRIDGE_VARS_FULL` in `R/transfer_learning.R` if relevant for domain adaptation

### R module style
- No side effects in functions (no `setwd()`, no `write_csv()` outside output functions)
- Use `message("[prefix] ...")` for progress, not `cat()` or `print()`
- `suppressPackageStartupMessages({ library(...) })` inside each function
- `%||%` null-coalescing operator available from `depth_harmonization.R`

---

## Current build status

| Step | Status | Notes |
|------|--------|-------|
| Step 1 — Data prep + harmonization | Complete | Terrestrial depth scheme |
| Step 2 — Simple extrapolation | Complete | |
| Step 3 — Random forest | Complete | |
| Pre-analysis — Global GEE extraction | Converted | WoSIS + CanPeat + AgriCanada |
| Step 4 — Transfer learning (Wadoux) | Converted | Terrestrial bridge variables |
| Step 5 — Transfer learning (Embeddings) | In progress | |

---

## Data sources and download links

| Dataset | URL / DOI |
|---------|-----------|
| WoSIS 2023 | https://www.isric.org/explore/wosis/faq-wosis-database |
| CanPeat | https://doi.org/10.5194/essd-13-3945-2021 |
| Agriculture Canada NSDB | https://open.canada.ca/data (search "National Soil DataBase") |
| SoilGrids v2.0 | https://www.isric.org/explore/soilgrids |
| ESA WorldCover 10m | https://worldcover2021.esa.int |
| GLiM lithology | https://doi.org/10.1594/PANGAEA.788537 |
| FAO SOC Mapping Cookbook | https://openknowledge.fao.org |
