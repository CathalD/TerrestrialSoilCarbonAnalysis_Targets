# ============================================================================
# TERRESTRIAL SOIL CARBON PROJECT CONFIGURATION
# Edit the values below for your specific site and dataset.
# ============================================================================

# ── Project metadata ──────────────────────────────────────────────────────────
PROJECT_NAME     <- "TerrestrialSOC_2026_Example"
PROJECT_SCENARIO <- "PROJECT"   # BASELINE | PROJECT | CONTROL | DEGRADED
MONITORING_YEAR  <- 2026
PROJECT_LOCATION <- "Example Upland Site"

# ── Google Earth Engine ───────────────────────────────────────────────────────
GEE_PROJECT <- "north-star-project-470316"

# ── Input file paths ──────────────────────────────────────────────────────────
PRE_ANALYSIS_DIR <- "Pre-Analysis Data Preparation"
DATA_RAW_DIR     <- file.path(PRE_ANALYSIS_DIR, "data_raw")
DATA_GLOBAL_DIR  <- file.path(PRE_ANALYSIS_DIR, "data_global")
COVARIATES_DIR   <- file.path(PRE_ANALYSIS_DIR, "covariates")

# Remote sensing covariate raster (multi-band GEE export — 28 terrestrial bands)
COVARIATE_RASTER <- file.path(COVARIATES_DIR, "TerrestrialSOC_Covariate_Snapshot_25m_2020_2023.tif")

# Area of Interest boundary (GeoJSON, shapefile, or GPKG)
AOI_FILE <- file.path(DATA_RAW_DIR, "aoi_boundary.geojson")

# Column in AOI_FILE that identifies land-use strata.
# Set to NULL for a whole-site total (no per-stratum area breakdown).
AOI_STRATUM_FIELD <- NULL  # e.g. "landuse_class"

# ── Land-use strata ───────────────────────────────────────────────────────────
# Codes must match the `stratum` column in core_locations.csv.
# Common terrestrial classes: Forest (F), Grassland (GL), Cropland (CL),
# Peatland (PL), Shrubland (SL), Wetland (WL).
VALID_STRATA <- c("F", "GL", "CL")

STRATUM_COLORS <- c(
  "F"  = "#2d6a4f",   # Forest — dark green
  "GL" = "#95d5b2",   # Grassland — light green
  "CL" = "#f4a261"    # Cropland — orange
)

# ── Standard depth intervals ──────────────────────────────────────────────────
# Four-depth scheme aligned with IPCC Tier 2 reporting (0–30 cm, 0–100 cm)
# and the GlobalSoilMap specification.
# Depths 1–2 aggregate to the standard 0–30 cm topsoil pool.
# Depths 1–4 aggregate to the standard 0–100 cm full-profile pool.
DEPTH_MIDPOINTS <- c(7.5, 22.5, 45, 80)

DEPTH_INTERVALS <- data.frame(
  depth_top      = c( 0, 15, 30,  60),
  depth_bottom   = c(15, 30, 60, 100),
  depth_midpoint = c(7.5, 22.5, 45, 80),
  thickness_cm   = c(15, 15, 30, 40)
)

# ── Bulk density defaults ─────────────────────────────────────────────────────
# Applied where bulk_density_g_cm3 is missing in the sample data (g/cm³).
# Literature values for Canadian terrestrial ecosystems (Gregorich et al. 1994;
# Jandl et al. 2014). Update for your specific ecosystem type.
BD_DEFAULTS <- list(
  "F"  = 0.90,   # Forest mineral soil — moderate OM, variable texture
  "GL" = 1.20,   # Grassland — denser, lower OM mineral soil
  "CL" = 1.30    # Cropland — compacted tilled mineral soil
)

# ── QC thresholds ─────────────────────────────────────────────────────────────
QC_SOC_MIN <- 0      # g/kg — minimum valid SOC
QC_SOC_MAX <- 600    # g/kg — max for mineral soils; raise to ~900 for peatland sites
QC_BD_MIN  <- 0.05   # g/cm³ — allow low values for organic/peat horizons
QC_BD_MAX  <- 2.0    # g/cm³ — typical upper limit for mineral soils

# ── Remote sensing band labels ────────────────────────────────────────────────
# Maps GEE raster band names → human-readable labels for RF importance plots.
# Canonical 28-band terrestrial stack (see R/preanalysis/gee_covariates.R).
#
# Literature context:
#   NDVI, EVI, and LSWI are the strongest optical predictors of SOC in
#   mineral soils (Guo et al. 2022; Hengl et al. 2017).
#   SAR VV/VH captures soil roughness and residue cover (Paloscia et al. 2013).
#   Climate (MAT, MAP, PET) and topography (TWI, slope) are primary drivers
#   of SOC formation and decomposition rates (IPCC Tier 1 factors).
#   Clay content (SoilGrids prior) stabilises SOC through organo-mineral
#   associations and is one of the strongest global SOC predictors (Jobbagy & Jackson 2000).
BAND_LABELS <- c(
  # Topography
  "elevation_m" = "Elevation (m) — drainage, temperature lapse ★",
  "slope"       = "Slope (°) — erosion, drainage ★",
  "aspect"      = "Aspect (°) — solar radiation, evapotranspiration",
  "twi"         = "TWI — topographic wetness, soil moisture ★",
  "tpi"         = "TPI — topographic position (ridge/hollow)",
  "curvature"   = "Curvature — flow convergence/divergence",

  # SAR Sentinel-1
  "VV_mean"    = "SAR VV — soil moisture & surface roughness ★",
  "VH_mean"    = "SAR VH — vegetation volume scattering / biomass ★",
  "VVVH_ratio" = "SAR VV/VH ratio — canopy vs. bare soil",

  # Sentinel-2 optical raw
  "B"    = "S2 Blue (490 nm) — atmospheric scattering",
  "G"    = "S2 Green (560 nm) — chlorophyll reflectance",
  "R"    = "S2 Red (665 nm) — chlorophyll absorption",
  "B5"   = "S2 Red-Edge 1 (705 nm) — chlorophyll edge",
  "B6"   = "S2 Red-Edge 2 (740 nm) — canopy structure",
  "B7"   = "S2 Red-Edge 3 (783 nm) — LAI proxy",
  "NIR"  = "S2 NIR (842 nm) — vegetation biomass ★",
  "SWIR1"= "S2 SWIR-1 (1610 nm) — soil & canopy moisture ★",
  "SWIR2"= "S2 SWIR-2 (2190 nm) — soil organic matter & dry matter ★",

  # Sentinel-2 derived indices
  "NDVI_median" = "NDVI — live green vegetation density ★",
  "EVI_median"  = "EVI — canopy structure (atmosphere-corrected) ★",
  "LSWI_median" = "LSWI — land surface water index / soil moisture",
  "SAVI_median" = "SAVI — vegetation with soil-brightness correction",
  "NDMI_median" = "NDMI — plant water stress & canopy moisture ★",
  "BSI_median"  = "BSI — bare soil / exposed mineral surface ★",

  # Climate
  "MAT_C"        = "MAT — mean annual temperature (°C) ★",
  "MAP_mm"       = "MAP — mean annual precipitation (mm) ★",
  "PET_mm"       = "PET — potential evapotranspiration (mm/yr) ★",
  "aridity_index"= "Aridity index (MAP/PET) — water balance ★"
)
