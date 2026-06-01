# Terrestrial Soil Carbon Analysis

R workflow for estimating soil organic carbon (SOC) stocks in forest and grassland
ecosystems. Built for use with Canadian field data and IPCC Tier 2 depth reporting
(0–30 cm topsoil, 0–100 cm full mineral profile).

A Shiny app guides you through data upload and configuration. A `targets` pipeline
does the analysis and renders an HTML report.

---

## Get started

### 1. Clone the repository

```r
usethis::create_from_github(
  "CathalD/TerrestrialSoilCarbonAnalysis_Targets",
  destdir = "~/projects",
  fork = FALSE
)
```

Or via RStudio: **File → New Project → Version Control → Git**.

### 2. Install packages

```r
install.packages(c(
  "targets", "tarchetypes", "geotargets",
  "shiny", "bslib", "DT",
  "dplyr", "readr", "tidyr", "ggplot2",
  "sf", "terra",
  "ranger", "randomForest",
  "quarto"
))
```

### 3. Launch the setup app

Open the project in RStudio (the `.Rprofile` loads automatically), then run:

```r
shiny::runApp("shiny")

# or use the .Rprofile shortcut loaded automatically when the project opens:
app()
```

The app walks through four steps:

| Step | What you do |
|------|-------------|
| 1. Project Setup | Name, location, year, stratum codes |
| 2. Field Data | Upload `core_locations.csv` and `core_samples.csv` |
| 3. Site Boundary | Upload a GeoJSON with strata polygons — area per stratum is calculated automatically |
| 4. Save & Configure | Review data checks, save config, get copy-paste pipeline commands |

After saving, switch to the **Run** tab for the pipeline commands.

---

## Data format

**`core_locations.csv`** — one row per core:

| Column | Type | Description |
|--------|------|-------------|
| `core_id` | character | Unique identifier |
| `latitude` | numeric | Decimal degrees, WGS84 |
| `longitude` | numeric | Decimal degrees, WGS84 |
| `stratum` | character | Must match the codes entered in Step 1 of the app |

**`core_samples.csv`** — one row per depth sample:

| Column | Type | Description |
|--------|------|-------------|
| `core_id` | character | Links to `core_locations.csv` |
| `depth_top_cm` | numeric | Top of sampled interval (cm) |
| `depth_bottom_cm` | numeric | Bottom of sampled interval (cm) |
| `soc_g_kg` | numeric | Soil organic carbon (g C per kg dry soil) |
| `bulk_density_g_cm3` | numeric | Bulk density (g/cm³) — may be `NA` |

**Strata GeoJSON** — polygons where one attribute column contains the stratum codes.
The app automatically detects the correct column by matching values against the codes
you entered in Step 1. If it cannot match, it tells you exactly what it was looking
for and what it found.

---

## What the analysis produces

`targets::tar_make()` generates `reports/step1_nonspatial.html` with:

- SOC depth profiles for each core
- Per-stratum carbon stock table at all four IPCC Tier 2 depth intervals
- Area-weighted total carbon stock per stratum (if a strata GeoJSON was uploaded)
- Data quality flags: missing bulk density, depth extrapolation, strata with fewer than 3 cores

---

## Depth intervals (IPCC Tier 2)

| Interval  | Midpoint | Thickness |
|-----------|----------|-----------|
| 0–15 cm   | 7.5 cm   | 15 cm     |
| 15–30 cm  | 22.5 cm  | 15 cm     |
| 30–60 cm  | 45 cm    | 30 cm     |
| 60–100 cm | 80 cm    | 40 cm     |

0–30 cm sums to the IPCC topsoil pool; 0–100 cm is the full mineral profile.

---

## Test data

Sample data for a southern Ontario restoration chronosequence is in
`Pre-Analysis Data Preparation/data_raw/`:

- `core_locations.csv` — 8 cores across 4 restoration-age strata
- `core_samples.csv` — 98 depth samples
- `Alderville_Restoration.geojson` — site boundary with strata polygons

---

## Advanced pipelines

The non-spatial analysis (above) is the MVP. Additional pipelines are available
once a covariate raster and Google Earth Engine project are configured:

| Pipeline | What it adds |
|----------|-------------|
| RF spatial maps | 25 m carbon stock map across the site using local random forest |
| Wadoux transfer learning | Borrows signal from global terrestrial soil profiles weighted by site similarity |
| Embedding transfer learning | Same as Wadoux but uses Google's 64-d satellite foundation model for similarity |

See `CLAUDE.md` and `PIPELINE.md` for full technical documentation.
