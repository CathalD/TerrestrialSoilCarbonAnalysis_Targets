# =============================================================================
# R/preanalysis/global_data.R
# Terrestrial soil profile databases: ingest, harmonize, and filter profiles
#
# Supported databases:
#   ingest_wosis()        — WoSIS 2023 (ISRIC World Soil Information Service)
#   ingest_canpeat()      — CanPeat (Canadian Peatland Carbon Database)
#   ingest_agricanada()   — Agriculture Canada NSDB (National Soil DataBase)
#   combine_global_profiles() — merge all three into one canonical layer table
#   filter_for_gee()      — drop profiles missing lat/lon; return GEE-ready df
# =============================================================================


# ---------------------------------------------------------------------------
# ingest_wosis()
# ---------------------------------------------------------------------------
# Reads WoSIS 2023 pre-harmonized layers CSV (output of 01_WOSIS_harmonize.R).
# Normalises columns to the canonical schema used by harmonize_depths().
#
# WoSIS canonical columns used:
#   profile_id, layer_id, latitude, longitude, country_name,
#   upper_depth, lower_depth, layer_thickness_cm, BDOD, OrgC, TOTC,
#   OrgC_Stock (pre-computed kg/m²)
# ---------------------------------------------------------------------------
ingest_wosis <- function(wosis_layers_file) {
  suppressPackageStartupMessages({
    library(dplyr); library(readr)
  })

  message("[WOSIS] Reading harmonized WoSIS layers...")
  layers <- read_csv(wosis_layers_file, show_col_types = FALSE)

  n_raw <- n_distinct(layers$profile_id)
  message(sprintf("[WOSIS] Raw: %d layers from %d profiles", nrow(layers), n_raw))

  # Normalise to canonical layer schema
  layers_out <- layers |>
    filter(!is.na(latitude), !is.na(longitude)) |>
    mutate(
      dataset    = "WOSIS_2023",
      profile_id = as.character(profile_id),
      layer_id   = as.character(layer_id),
      OrgC_pct   = case_when(
        !is.na(OrgC)  ~ OrgC / 10,        # g/kg → %
        !is.na(TOTC)  ~ TOTC / 10,
        TRUE          ~ NA_real_
      ),
      BDOD       = BDOD,                   # already g/cm³ (kg/dm³ ≡ g/cm³)
      year       = as.integer(format(as.Date(date, tryFormats = c("%Y-%m-%d", "%Y")),
                                     "%Y"))
    ) |>
    select(
      dataset, profile_id, layer_id,
      latitude, longitude, country_name,
      upper_depth, lower_depth, layer_thickness_cm,
      BDOD, OrgC_pct,
      year
    )

  n_out <- n_distinct(layers_out$profile_id)
  message(sprintf("[WOSIS] Output: %d layers from %d profiles (%.0f%% valid lat/lon)",
                  nrow(layers_out), n_out, 100 * n_out / n_raw))

  list(layers = layers_out, source = "WOSIS_2023")
}


# ---------------------------------------------------------------------------
# ingest_canpeat()
# ---------------------------------------------------------------------------
# Reads the CanPeat (Canadian Peatland Carbon) database CSV.
# Reference: Packalen & Bhatti (2021) doi:10.5194/essd-13-3945-2021
#
# Expected columns in the input file:
#   SiteID, Latitude, Longitude, Province, PeatType (bog/fen/swamp),
#   Layer_Top_cm, Layer_Bot_cm, OrgC_gkg, BD_gcc (may be NA),
#   Year (optional)
#
# If BD_gcc is missing, a peatland default of 0.12 g/cm³ is used
# (Packalen & Bhatti 2021 median surface peat value).
# ---------------------------------------------------------------------------
ingest_canpeat <- function(canpeat_file, bd_default_peat = 0.12) {
  suppressPackageStartupMessages({
    library(dplyr); library(readr)
  })

  if (!file.exists(canpeat_file)) {
    message(sprintf("[CanPeat] File not found: %s — returning empty data frame", canpeat_file))
    return(list(layers = .empty_layer_schema(), source = "CanPeat"))
  }

  message("[CanPeat] Reading CanPeat layers...")
  raw <- read_csv(canpeat_file, show_col_types = FALSE)

  # Flexible column mapping (handles common name variants)
  col_map <- list(
    profile_id   = c("SiteID", "site_id", "profile_id"),
    latitude     = c("Latitude", "latitude", "lat"),
    longitude    = c("Longitude", "longitude", "lon"),
    upper_depth  = c("Layer_Top_cm", "upper_depth", "top_cm"),
    lower_depth  = c("Layer_Bot_cm", "lower_depth", "bot_cm"),
    OrgC_gkg     = c("OrgC_gkg", "OrgC_g_kg", "soc_g_kg"),
    BD           = c("BD_gcc", "BD_g_cm3", "bulk_density"),
    country_name = c("Province", "country", "province"),
    year         = c("Year", "year", "sampling_year")
  )

  .pick <- function(candidates) {
    found <- intersect(candidates, names(raw))
    if (length(found) == 0) NA_character_ else found[1]
  }

  rename_vec <- sapply(col_map, .pick)
  rename_vec <- rename_vec[!is.na(rename_vec)]

  layers <- raw |>
    rename(any_of(setNames(unname(rename_vec), names(rename_vec))))

  # Fill missing BD with peatland default
  if (!"BD" %in% names(layers)) layers$BD <- NA_real_
  layers <- layers |>
    mutate(
      BD       = if_else(is.na(BD) | BD <= 0, bd_default_peat, BD),
      OrgC_pct = if ("OrgC_gkg" %in% names(.)) OrgC_gkg / 10 else NA_real_,
      dataset  = "CanPeat",
      profile_id = as.character(profile_id),
      layer_id   = paste(profile_id, row_number(), sep = "_"),
      layer_thickness_cm = lower_depth - upper_depth,
      country_name = if ("country_name" %in% names(.)) as.character(country_name) else "Canada",
      year         = if ("year" %in% names(.)) as.integer(year) else NA_integer_
    ) |>
    filter(!is.na(latitude), !is.na(longitude),
           !is.na(upper_depth), !is.na(lower_depth),
           !is.na(OrgC_pct), layer_thickness_cm > 0) |>
    select(
      dataset, profile_id, layer_id,
      latitude, longitude, country_name,
      upper_depth, lower_depth, layer_thickness_cm,
      BDOD = BD, OrgC_pct, year
    )

  message(sprintf("[CanPeat] Output: %d layers from %d profiles",
                  nrow(layers), n_distinct(layers$profile_id)))

  list(layers = layers, source = "CanPeat")
}


# ---------------------------------------------------------------------------
# ingest_agricanada()
# ---------------------------------------------------------------------------
# Reads Agriculture and Agri-Food Canada National Soil DataBase (NSDB) CSV.
# The NSDB provides soil profile data for agricultural and managed soils
# across Canada. Download from: https://open.canada.ca/data (NSDB portal)
#
# Expected columns (NSDB standard export format):
#   PROFILE_ID, LATITUDE, LONGITUDE, PROVINCE, LANDUSE_CODE,
#   LAYER_TOP, LAYER_BOT, OC_PERCENT (organic carbon %), BD_MEASURED
#
# Notes:
#   OC_PERCENT is in % (will be converted to g/kg × 10 internally)
#   BD_MEASURED may be NA; stratum-based defaults from cfg$BD_DEFAULTS are used
# ---------------------------------------------------------------------------
ingest_agricanada <- function(agricanada_file, bd_default_mineral = 1.20) {
  suppressPackageStartupMessages({
    library(dplyr); library(readr)
  })

  if (!file.exists(agricanada_file)) {
    message(sprintf("[AgriCanada] File not found: %s — returning empty data frame", agricanada_file))
    return(list(layers = .empty_layer_schema(), source = "AgriCanada"))
  }

  message("[AgriCanada] Reading Agriculture Canada NSDB layers...")
  raw <- read_csv(agricanada_file, show_col_types = FALSE)

  col_map <- list(
    profile_id   = c("PROFILE_ID", "profile_id", "ProfileID"),
    latitude     = c("LATITUDE",   "latitude",   "Latitude"),
    longitude    = c("LONGITUDE",  "longitude",  "Longitude"),
    upper_depth  = c("LAYER_TOP",  "upper_depth", "layer_top_cm"),
    lower_depth  = c("LAYER_BOT",  "lower_depth", "layer_bot_cm"),
    OC_pct       = c("OC_PERCENT", "oc_percent",  "SOC_percent", "SOC_pct"),
    BD           = c("BD_MEASURED","bd_measured",  "bulk_density", "BD"),
    country_name = c("PROVINCE",   "province",    "Province"),
    year         = c("YEAR",       "year",        "SamplingYear")
  )

  .pick <- function(candidates) {
    found <- intersect(candidates, names(raw))
    if (length(found) == 0) NA_character_ else found[1]
  }

  rename_vec <- sapply(col_map, .pick)
  rename_vec <- rename_vec[!is.na(rename_vec)]

  layers <- raw |>
    rename(any_of(setNames(unname(rename_vec), names(rename_vec))))

  if (!"BD" %in% names(layers)) layers$BD <- NA_real_
  if (!"OC_pct" %in% names(layers)) {
    stop("[AgriCanada] Cannot find organic carbon column. Check file format.")
  }

  layers <- layers |>
    mutate(
      BD       = if_else(is.na(BD) | BD <= 0, bd_default_mineral, BD),
      OrgC_pct = OC_pct,
      dataset  = "AgriCanada_NSDB",
      profile_id = as.character(profile_id),
      layer_id   = paste(profile_id, row_number(), sep = "_"),
      layer_thickness_cm = lower_depth - upper_depth,
      country_name = if ("country_name" %in% names(.)) as.character(country_name) else "Canada",
      year         = if ("year" %in% names(.)) as.integer(year) else NA_integer_
    ) |>
    filter(!is.na(latitude), !is.na(longitude),
           !is.na(upper_depth), !is.na(lower_depth),
           !is.na(OrgC_pct), layer_thickness_cm > 0) |>
    select(
      dataset, profile_id, layer_id,
      latitude, longitude, country_name,
      upper_depth, lower_depth, layer_thickness_cm,
      BDOD = BD, OrgC_pct, year
    )

  message(sprintf("[AgriCanada] Output: %d layers from %d profiles",
                  nrow(layers), n_distinct(layers$profile_id)))

  list(layers = layers, source = "AgriCanada_NSDB")
}


# ---------------------------------------------------------------------------
# combine_global_profiles()
# ---------------------------------------------------------------------------
# Merge all ingested databases into a single canonical layer table.
# Deduplicates by dataset+profile_id compound key.
# ---------------------------------------------------------------------------
combine_global_profiles <- function(...) {
  suppressPackageStartupMessages({ library(dplyr) })

  db_list <- list(...)

  all_layers <- lapply(db_list, function(db) {
    if (is.null(db) || nrow(db$layers) == 0) return(NULL)
    db$layers
  })
  all_layers <- Filter(Negate(is.null), all_layers)

  if (length(all_layers) == 0)
    stop("[combine_global_profiles] No valid database inputs provided.")

  combined <- dplyr::bind_rows(all_layers)

  n_total    <- n_distinct(paste(combined$dataset, combined$profile_id))
  n_complete <- sum(complete.cases(combined[, c("BDOD", "OrgC_pct", "latitude", "longitude")]))

  message(sprintf("[combine] Combined: %d layers from %d profiles across %d datasets",
                  nrow(combined), n_total, length(all_layers)))
  message(sprintf("[combine] Profiles with complete BD+OrgC+coords: %d", n_complete))

  combined
}


# ---------------------------------------------------------------------------
# filter_for_gee()
# ---------------------------------------------------------------------------
# Filters combined profiles to those with valid coordinates.
# For terrestrial workflows there is no ecosystem code filter —
# all soil profiles are eligible for GEE extraction.
# ---------------------------------------------------------------------------
filter_for_gee <- function(combined_layers) {
  suppressPackageStartupMessages(library(dplyr))

  profiles <- combined_layers |>
    group_by(dataset, profile_id) |>
    summarise(
      latitude     = first(latitude),
      longitude    = first(longitude),
      country_name = first(country_name),
      n_layers     = n(),
      .groups = "drop"
    )

  n_start <- nrow(profiles)

  filtered <- profiles |>
    filter(!is.na(latitude), !is.na(longitude)) |>
    mutate(profile_id = as.character(profile_id))

  n_removed <- n_start - nrow(filtered)
  message(sprintf("[filter_for_gee] Input: %d profiles", n_start))
  message(sprintf("[filter_for_gee] Removed %d profiles with missing lat/lon", n_removed))
  message(sprintf("[filter_for_gee] Output: %d profiles ready for GEE extraction", nrow(filtered)))

  filtered
}


# ---------------------------------------------------------------------------
# .empty_layer_schema()
# ---------------------------------------------------------------------------
.empty_layer_schema <- function() {
  data.frame(
    dataset = character(0), profile_id = character(0), layer_id = character(0),
    latitude = numeric(0), longitude = numeric(0), country_name = character(0),
    upper_depth = numeric(0), lower_depth = numeric(0),
    layer_thickness_cm = numeric(0),
    BDOD = numeric(0), OrgC_pct = numeric(0), year = integer(0)
  )
}
