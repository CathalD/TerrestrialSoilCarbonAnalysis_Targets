# ============================================================================
# SOIL CARBON CONFIGURATION — HUDSON / JAMES BAY LOWLANDS (PEATLAND)
# Peatland adaptation of the workflow. To use it:
#   cp soil_carbon_config.HBL.example.R soil_carbon_config.R
# then edit the strata / paths to match YOUR area of interest.
# ============================================================================

# ── Project metadata ──────────────────────────────────────────────────────────
PROJECT_NAME     <- "HudsonBayLowlands_Peatland_2026"
PROJECT_SCENARIO <- "BASELINE"
MONITORING_YEAR  <- 2026
PROJECT_LOCATION <- "Hudson & James Bay Lowlands, Ontario, Canada"

# ── Google Earth Engine ───────────────────────────────────────────────────────
GEE_PROJECT <- ""   # set before running the spatial / GEE pipelines

# ── Input file paths ──────────────────────────────────────────────────────────
PRE_ANALYSIS_DIR <- "Pre-Analysis Data Preparation"
DATA_RAW_DIR     <- file.path(PRE_ANALYSIS_DIR, "data_raw")
DATA_GLOBAL_DIR  <- file.path(PRE_ANALYSIS_DIR, "data_global")
COVARIATES_DIR   <- file.path(PRE_ANALYSIS_DIR, "covariates")

COVARIATE_RASTER <- file.path(COVARIATES_DIR, "HBL_Covariate_Snapshot.tif")

# Area of Interest = Far North Land Cover polygons (or your classified wetland map).
AOI_FILE <- file.path(DATA_RAW_DIR, "FarNorthLandCover_AOI.geojson")
# Polygon attribute holding the land-cover class (must match VALID_STRATA exactly).
AOI_STRATUM_FIELD <- "LC_CLASS"

# ── Land-cover strata (Far North Land Cover classes) ──────────────────────────
# EDIT to the classes present in your AOI. Codes must match the `stratum` column
# in core_locations.csv AND the AOI polygon class values, exactly.
VALID_STRATA <- c("Open Bog", "Treed Bog", "Open Fen", "Treed Fen",
                  "Swamp", "Marsh", "Open Water", "Treed Upland")

STRATUM_COLORS <- c(
  "Open Bog"     = "#b7d9a8",   # open peatland — light green
  "Treed Bog"    = "#6aa84f",   # treed bog
  "Open Fen"     = "#a8c6d9",   # fen — bluish (minerotrophic)
  "Treed Fen"    = "#3d85c6",
  "Swamp"        = "#7f6000",   # forested wetland — brown
  "Marsh"        = "#bf9000",
  "Open Water"   = "#1c4587",
  "Treed Upland" = "#274e13"    # mineral upland — dark green
)

# ── Bulk density defaults (g/cm³) — PEAT values, ~10x lower than mineral soils ─
# Applied where bulk_density_g_cm3 is missing. Replace with local measurements.
BD_DEFAULTS <- list(
  "Open Bog"     = 0.08,
  "Treed Bog"    = 0.09,
  "Open Fen"     = 0.11,
  "Treed Fen"    = 0.12,
  "Swamp"        = 0.15,
  "Marsh"        = 0.20,
  "Open Water"   = 0.05,
  "Treed Upland" = 0.80   # mineral upland, not peat
)

# ── Soil profile type — controls depth extrapolation ──────────────────────────
# "organic" = peat: SOC stays high and roughly flat with depth, so the deepest
# measured value is carried downward (NO mineral-soil exponential decay).
PROFILE_TYPE      <- "organic"
MAX_EXTRAP_FACTOR <- 3      # allow constant extrapolation to 3x the deepest sample

# ── SOC input format ──────────────────────────────────────────────────────────
# If core_samples.csv provides loss-on-ignition / organic-matter % (column
# `organic_matter_pct`, `loi_pct`, or `om_pct`) instead of `soc_g_kg`, it is
# converted to carbon as:  soc_g_kg = OM_percent * 10 * OM_TO_C_FACTOR
OM_TO_C_FACTOR <- 0.50      # carbon fraction of peat organic matter (~0.50)

# ── Standard depth intervals — deep peat scheme (to 200 cm) ───────────────────
# Aggregates: 0–30 cm (surface), 0–100 cm, and 0–200 cm (full reported profile).
DEPTH_MIDPOINTS <- c(7.5, 22.5, 45, 80, 125, 175)

DEPTH_INTERVALS <- data.frame(
  depth_top      = c( 0, 15, 30,  60, 100, 150),
  depth_bottom   = c(15, 30, 60, 100, 150, 200),
  depth_midpoint = c(7.5, 22.5, 45, 80, 125, 175),
  thickness_cm   = c(15, 15, 30, 40, 50, 50)
)

# ── QC thresholds ─────────────────────────────────────────────────────────────
QC_SOC_MIN <- 0      # g/kg
QC_SOC_MAX <- 600    # g/kg — peat is ~45–55% C
QC_BD_MIN  <- 0.02   # g/cm³ — peat can be very light
QC_BD_MAX  <- 2.0    # g/cm³ — upper limit for mineral substrate layers

# ── Remote sensing band labels ────────────────────────────────────────────────
# 28-band terrestrial canonical stack. For peatlands the SAR (VV/VH), wetness
# (TWI, LSWI/NDMI) and any peat-depth / surface-water layers matter most; the
# mineral-soil covariates (clay, lithology) matter less.
BAND_LABELS <- c(
  "elevation_m" = "Elevation (m) — drainage, temperature lapse ★",
  "slope"       = "Slope (°) — drainage (very flat terrain) ",
  "aspect"      = "Aspect (°) — solar radiation",
  "twi"         = "TWI — topographic wetness / waterlogging ★",
  "tpi"         = "TPI — topographic position (microtopography)",
  "curvature"   = "Curvature — flow convergence/divergence",
  "VV_mean"    = "SAR VV — surface wetness & inundation ★",
  "VH_mean"    = "SAR VH — vegetation volume / wetland structure ★",
  "VVVH_ratio" = "SAR VV/VH ratio — open vs. treed wetland",
  "B"    = "S2 Blue (490 nm)",
  "G"    = "S2 Green (560 nm)",
  "R"    = "S2 Red (665 nm)",
  "B5"   = "S2 Red-Edge 1 (705 nm)",
  "B6"   = "S2 Red-Edge 2 (740 nm)",
  "B7"   = "S2 Red-Edge 3 (783 nm)",
  "NIR"  = "S2 NIR (842 nm) — vegetation biomass ★",
  "SWIR1"= "S2 SWIR-1 (1610 nm) — canopy & soil moisture ★",
  "SWIR2"= "S2 SWIR-2 (2190 nm) — organic / dry matter ★",
  "NDVI_median" = "NDVI — green vegetation density",
  "EVI_median"  = "EVI — canopy structure",
  "LSWI_median" = "LSWI — land surface water / inundation ★",
  "SAVI_median" = "SAVI — soil-adjusted vegetation",
  "NDMI_median" = "NDMI — canopy / surface moisture ★",
  "BSI_median"  = "BSI — bare surface (rare in peatland)",
  "MAT_C"        = "MAT — mean annual temperature (°C) ★",
  "MAP_mm"       = "MAP — mean annual precipitation (mm) ★",
  "PET_mm"       = "PET — potential evapotranspiration (mm/yr)",
  "aridity_index"= "Aridity index (MAP/PET) — water balance"
)
