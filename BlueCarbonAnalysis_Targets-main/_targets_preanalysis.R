# =============================================================================
# _targets_preanalysis.R
# Pre-analysis pipeline: global soil data preparation + GEE covariate extraction
#
# Run with:
#   targets::tar_make(script = "_targets_preanalysis.R",
#                     store  = "_targets_preanalysis")
#
# Prerequisites:
#   1. Place input data files (see Phase 1 paths below).
#   2. Install and authenticate rgee (run once):
#        source("Pre-Analysis Data Preparation/GEE_R/00_setup_rgee.R")
#   3. Run the main pipeline first to ensure packages are available.
#
# Pipeline structure:
#
#   Phase 1 — Global data ingestion (fast, no GEE needed):
#     wosis_data          : WoSIS 2023 layers + profiles
#     canpeat_data        : CanPeat Canadian peatland layers
#     agricanada_data     : Agriculture Canada NSDB layers
#     combined_layers     : merged canonical layer table
#     profiles_for_gee    : profiles with valid lat/lon, ready for extraction
#
#   Phase 2 — GEE covariate extraction (requires rgee + authentication):
#     gee_climate         : TerraClimate MAT/MAP/PET/aridity (2000–2022)
#     gee_topo            : 6-band terrain stack (30 m)
#     gee_sar             : Sentinel-1 VV/VH composite (2020–2023, 30 m)
#     gee_s2              : S2 raw (9 bands) + derived (6 bands) (2020–2023, 30 m)
#
#   Phase 3 — Combine + output:
#     global_covariates   : Merged 28-band canonical data.frame
#     covariates_file     : TerrestrialSOC_GlobalCorePoints_Covariates.csv
#
# Adding a new database:
#   1. Write ingest_xyz() in R/preanalysis/global_data.R
#   2. Add tar_target(xyz_data, ingest_xyz(...)) below
#   3. Add xyz_data to combine_global_profiles() call in combined_layers target
# =============================================================================

library(targets)
library(tarchetypes)

lapply(
  list.files("R/preanalysis", pattern = "\\.R$", full.names = TRUE),
  source
)

# ── Test mode ──────────────────────────────────────────────────────────────────
TEST_MODE <- FALSE
TEST_N    <- 50L
GEE_PROJECT <- "north-star-project-470316"

# ── Input file paths ───────────────────────────────────────────────────────────
# WoSIS: pre-harmonized layers CSV from Pre-Analysis Data Preparation/R_Scripts/01_WOSIS_harmonize.R
WOSIS_LAYERS_FILE     <- file.path("Pre-Analysis Data Preparation", "data_global",
                                   "wosis_layers.csv")
# CanPeat: download from https://doi.org/10.5194/essd-13-3945-2021
CANPEAT_FILE          <- file.path("Pre-Analysis Data Preparation", "data_global",
                                   "canpeat_layers.csv")
# Agriculture Canada NSDB: download from https://open.canada.ca/data (search "NSDB")
AGRICANADA_FILE       <- file.path("Pre-Analysis Data Preparation", "data_global",
                                   "agricanada_nsdb_layers.csv")
# Output path
COVARIATES_OUT_PATH   <- file.path("Pre-Analysis Data Preparation", "data_raw",
                                   "TerrestrialSOC_GlobalCorePoints_Covariates.csv")

# ── Pipeline ──────────────────────────────────────────────────────────────────
list(

  # ── Phase 1: Raw data file inputs ──────────────────────────────────────────
  tar_target(wosis_file,     WOSIS_LAYERS_FILE,   format = "file"),
  tar_target(canpeat_file_t, CANPEAT_FILE,        format = "file"),
  tar_target(agricanada_file_t, AGRICANADA_FILE,  format = "file"),

  # ── Phase 1: Database ingestion ────────────────────────────────────────────
  tar_target(
    wosis_data,
    ingest_wosis(wosis_file)
  ),

  tar_target(
    canpeat_data,
    ingest_canpeat(canpeat_file_t)
  ),

  tar_target(
    agricanada_data,
    ingest_agricanada(agricanada_file_t)
  ),

  # ── Phase 1: Combine all databases ─────────────────────────────────────────
  tar_target(
    combined_layers,
    combine_global_profiles(wosis_data, canpeat_data, agricanada_data)
  ),

  # ── Phase 1: Filter profiles for GEE (valid lat/lon) ──────────────────────
  tar_target(
    profiles_for_gee,
    filter_for_gee(combined_layers)
  ),

  # ── Phase 1: Subsample for test mode ───────────────────────────────────────
  tar_target(
    profiles_for_extraction,
    if (TEST_MODE) {
      set.seed(42L)
      profiles_for_gee[sample(nrow(profiles_for_gee), min(TEST_N, nrow(profiles_for_gee))), ]
    } else {
      profiles_for_gee
    }
  ),

  # ── Phase 2: GEE covariate extraction ──────────────────────────────────────
  # Climate runs first (cheap, 4 km) — inspect before committing to S2.
  tar_target(
    gee_climate,
    extract_climate(profiles_for_extraction, gee_project = GEE_PROJECT)
  ),

  tar_target(
    gee_topo,
    extract_topo(profiles_for_extraction, gee_project = GEE_PROJECT)
  ),

  tar_target(
    gee_sar,
    extract_sar(profiles_for_extraction, gee_project = GEE_PROJECT)
  ),

  # S2 raw (9 bands) + derived indices (6 bands) in a single target
  tar_target(
    gee_s2,
    extract_s2_all(profiles_for_extraction, gee_project = GEE_PROJECT)
  ),

  # ── Phase 3: Combine all extractions ───────────────────────────────────────
  tar_target(
    global_covariates,
    combine_covariates(
      profiles_for_extraction,
      topo    = gee_topo,
      sar     = gee_sar,
      s2      = gee_s2,
      climate = gee_climate
    )
  ),

  # ── Phase 3: Write global layers CSV (read by _targets_transfer.R) ─────────
  # combined_layers_filtered.csv = harmonized profile data (SOC, BD, depth)
  # for all global soil cores with valid coordinates.
  tar_target(
    global_layers_file,
    {
      path <- file.path("Pre-Analysis Data Preparation", "data_global",
                        "combined_layers_filtered.csv")
      readr::write_csv(profiles_for_gee, path)
      path
    },
    format = "file"
  ),

  # ── Phase 3: Write covariate CSV (read by _targets_transfer.R + embedding) ──
  tar_target(
    covariates_file,
    write_covariates_csv(
      global_covariates,
      path = COVARIATES_OUT_PATH
    ),
    format = "file"
  )

)
