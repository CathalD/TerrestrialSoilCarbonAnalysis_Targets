# ============================================================================
# TERRESTRIAL SOIL CARBON PROJECT CONFIGURATION
# Edit the values below for your specific site and dataset.
# (This is the tracked template; it is copied to soil_carbon_config.R on first
#  run. For a peat-dominated site, start from soil_carbon_config.HBL.example.R.)
# ============================================================================

# ── Project metadata ──────────────────────────────────────────────────────────
PROJECT_NAME     <- "JamesBayLowlands_LandCover_2026"
PROJECT_SCENARIO <- "BASELINE"   # BASELINE | PROJECT | CONTROL | DEGRADED
MONITORING_YEAR  <- 2026
PROJECT_LOCATION <- "James Bay Lowlands, Ontario, Canada (Cochrane District)"

# ── Google Earth Engine ───────────────────────────────────────────────────────
GEE_PROJECT <- "north-star-project-470316"

# ── Input file paths ──────────────────────────────────────────────────────────
PRE_ANALYSIS_DIR <- "Pre-Analysis Data Preparation"
DATA_RAW_DIR     <- file.path(PRE_ANALYSIS_DIR, "data_raw")
DATA_GLOBAL_DIR  <- file.path(PRE_ANALYSIS_DIR, "data_global")
COVARIATES_DIR   <- file.path(PRE_ANALYSIS_DIR, "covariates")

# Remote sensing covariate raster (multi-band GEE export — 28 terrestrial bands)
COVARIATE_RASTER <- file.path(COVARIATES_DIR, "JamesBay_Covariate_Snapshot.tif")

# Area of Interest boundary (GeoJSON, shapefile, or GPKG)
AOI_FILE <- file.path(DATA_RAW_DIR, "strata_map_aoi.geojson")

# Column in AOI_FILE that identifies strata, OR NULL.
# This AOI is a single polygon whose per-stratum land-cover AREAS are given in
# STRATUM_AREAS below (the strata themselves come from the ESRI 10 m land cover,
# not from separate polygons), so there is no per-polygon stratum field.
AOI_STRATUM_FIELD <- NULL

# ── Land-cover strata (ESRI 10 m 2024, ESA 6-class) ───────────────────────────
# Codes must match the `stratum` column in core_locations.csv exactly.
VALID_STRATA <- c("Forest", "Herbaceous", "Wetland")

STRATUM_COLORS <- c(
  "Forest"     = "#1b5e20",   # boreal forest — dark green
  "Herbaceous" = "#c9a227",   # open / grassy — gold
  "Wetland"    = "#2b7ca3"    # wetland / organic — teal-blue
)

# ── Per-stratum areas (hectares) ──────────────────────────────────────────────
# Land-cover class areas within the AOI (from strata_map_aoi.geojson properties).
# Used to scale per-stratum carbon density to absolute total stocks.
STRATUM_AREAS <- c(
  "Forest"     = 1448.9,
  "Herbaceous" =  215.9,
  "Wetland"    =  580.4
)

# ── Bulk density defaults ─────────────────────────────────────────────────────
# Applied where bulk_density_g_cm3 is missing in the sample data (g/cm³).
# Boreal soils: mineral uplands (Forest/Herbaceous) vs. organic wetland.
BD_DEFAULTS <- list(
  "Forest"     = 0.90,   # boreal forest mineral soil
  "Herbaceous" = 1.10,   # open mineral soil
  "Wetland"    = 0.15    # organic / peat — much lower
)

# ── Soil profile type ─────────────────────────────────────────────────────────
# "mineral" (default): exponential-decay extrapolation below the deepest sample.
# Wetland here is treated within the standard 0–100 cm scheme. If your wetlands
# are deep peat, switch to the organic / deep-peat setup in
# soil_carbon_config.HBL.example.R (PROFILE_TYPE = "organic", depths to 200 cm).
PROFILE_TYPE <- "mineral"

# ── Standard depth intervals ──────────────────────────────────────────────────
# Four-depth scheme with standard aggregates (0–30 cm, 0–100 cm).
DEPTH_MIDPOINTS <- c(7.5, 22.5, 45, 80)

DEPTH_INTERVALS <- data.frame(
  depth_top      = c( 0, 15, 30,  60),
  depth_bottom   = c(15, 30, 60, 100),
  depth_midpoint = c(7.5, 22.5, 45, 80),
  thickness_cm   = c(15, 15, 30, 40)
)

# ── QC thresholds ─────────────────────────────────────────────────────────────
QC_SOC_MIN <- 0      # g/kg — minimum valid SOC
QC_SOC_MAX <- 600    # g/kg — covers organic wetland soils (~45–55% C)
QC_BD_MIN  <- 0.03   # g/cm³ — allow low values for organic/wetland horizons
QC_BD_MAX  <- 2.0    # g/cm³ — typical upper limit for mineral soils

# ── Remote sensing band labels ────────────────────────────────────────────────
# Maps GEE raster band names → human-readable labels for RF importance plots.
# Canonical 28-band terrestrial stack (see R/preanalysis/gee_covariates.R).
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
  "LSWI_median" = "LSWI — land surface water index / soil moisture ★",
  "SAVI_median" = "SAVI — vegetation with soil-brightness correction",
  "NDMI_median" = "NDMI — plant water stress & canopy moisture ★",
  "BSI_median"  = "BSI — bare soil / exposed mineral surface",

  # Climate
  "MAT_C"        = "MAT — mean annual temperature (°C) ★",
  "MAP_mm"       = "MAP — mean annual precipitation (mm) ★",
  "PET_mm"       = "PET — potential evapotranspiration (mm/yr) ★",
  "aridity_index"= "Aridity index (MAP/PET) — water balance ★"
)
