# R/data_prep.R
# PURPOSE: Load, merge, and prepare core data for analysis.
#   1. Reads core_locations.csv and core_samples.csv
#   2. Merges on core_id
#   3. Applies QC_* thresholds — out-of-range SOC / bulk density set to NA
#   4. Fills missing bulk density from cfg$BD_DEFAULTS (by stratum)
#   5. Computes carbon_stock_kg_m2 = SOC x BD x thickness / 100
load_raw_data <- function(locations_path, samples_path, cfg = NULL) {
  suppressPackageStartupMessages({
    library(dplyr)
    library(readr)
  })
  message("[data_prep] Reading raw CSVs...")
  locations <- read_csv(locations_path, show_col_types = FALSE)
  samples   <- read_csv(samples_path,   show_col_types = FALSE)

  # SOC may be supplied directly (soc_g_kg) or derived from loss-on-ignition /
  # organic-matter percent (peat workflows): soc_g_kg = OM% x 10 x OM_TO_C_FACTOR.
  if (!"soc_g_kg" %in% names(samples)) {
    om_col <- intersect(c("organic_matter_pct", "loi_pct", "om_pct"), names(samples))
    if (length(om_col) >= 1) {
      om_to_c <- if (is.null(cfg$OM_TO_C_FACTOR)) 0.58 else cfg$OM_TO_C_FACTOR
      samples$soc_g_kg <- suppressWarnings(as.numeric(samples[[om_col[1]]])) * 10 * om_to_c
      message(sprintf("[data_prep] Derived soc_g_kg from '%s' (x10 x %.2f C fraction).",
                      om_col[1], om_to_c))
    }
  }

  required_loc <- c("core_id", "longitude", "latitude", "stratum")
  required_smp <- c("core_id", "depth_top_cm", "depth_bottom_cm", "soc_g_kg")
  missing_loc  <- setdiff(required_loc, names(locations))
  missing_smp  <- setdiff(required_smp, names(samples))
  if (length(missing_loc) > 0)
    stop("core_locations.csv is missing columns: ", paste(missing_loc, collapse = ", "))
  if (length(missing_smp) > 0)
    stop("core_samples.csv is missing columns: ", paste(missing_smp, collapse = ", "))

  cores <- samples %>%
    left_join(locations, by = "core_id") %>%
    mutate(
      depth_top_cm       = suppressWarnings(as.numeric(depth_top_cm)),
      depth_bottom_cm    = suppressWarnings(as.numeric(depth_bottom_cm)),
      soc_g_kg           = suppressWarnings(as.numeric(soc_g_kg)),
      bulk_density_g_cm3 = suppressWarnings(as.numeric(bulk_density_g_cm3)),
      depth_cm           = (depth_top_cm + depth_bottom_cm) / 2,
      layer_thickness_cm = depth_bottom_cm - depth_top_cm
    )

  # ── QC gates ──────────────────────────────────────────────────────────────
  # Enforce the QC_* thresholds from config so out-of-range measurements (unit
  # errors, typos) don't propagate into carbon stocks. Offending values are set
  # to NA rather than dropped: NA SOC drops that layer in harmonization; NA bulk
  # density is back-filled from BD_DEFAULTS below.
  soc_min <- if (is.null(cfg$QC_SOC_MIN)) -Inf else cfg$QC_SOC_MIN
  soc_max <- if (is.null(cfg$QC_SOC_MAX))  Inf else cfg$QC_SOC_MAX
  bd_min  <- if (is.null(cfg$QC_BD_MIN))  -Inf else cfg$QC_BD_MIN
  bd_max  <- if (is.null(cfg$QC_BD_MAX))   Inf else cfg$QC_BD_MAX

  soc_bad <- !is.na(cores$soc_g_kg) &
    (cores$soc_g_kg < soc_min | cores$soc_g_kg > soc_max)
  bd_bad <- !is.na(cores$bulk_density_g_cm3) &
    (cores$bulk_density_g_cm3 < bd_min | cores$bulk_density_g_cm3 > bd_max)

  if (any(soc_bad)) {
    message(sprintf(
      "[data_prep] QC: %d SOC value(s) outside [%g, %g] g/kg set to NA (cores: %s).",
      sum(soc_bad), soc_min, soc_max,
      paste(sort(unique(cores$core_id[soc_bad])), collapse = ", ")))
    cores$soc_g_kg[soc_bad] <- NA_real_
  }
  if (any(bd_bad)) {
    message(sprintf(
      "[data_prep] QC: %d bulk-density value(s) outside [%g, %g] g/cm3 set to NA (cores: %s).",
      sum(bd_bad), bd_min, bd_max,
      paste(sort(unique(cores$core_id[bd_bad])), collapse = ", ")))
    cores$bulk_density_g_cm3[bd_bad] <- NA_real_
  }

  # Apply BD defaults where bulk_density_g_cm3 is missing
  bd_defaults <- cfg$BD_DEFAULTS
  if (!is.null(bd_defaults) && length(bd_defaults) > 0) {
    cores <- cores %>%
      mutate(
        bd_estimated = is.na(bulk_density_g_cm3),
        bulk_density_g_cm3 = if_else(
          bd_estimated,
          vapply(stratum, function(s) {
            val <- bd_defaults[[s]]
            if (is.null(val)) NA_real_ else as.numeric(val)
          }, numeric(1)),
          bulk_density_g_cm3
        )
      )
  } else {
    cores <- cores %>% mutate(bd_estimated = is.na(bulk_density_g_cm3))
  }

  cores <- cores %>%
    mutate(
      carbon_stock_kg_m2 = (soc_g_kg * bulk_density_g_cm3 * layer_thickness_cm) / 100
    )

  message(sprintf("[data_prep] %d samples from %d cores. BD defaults applied: %d.",
                  nrow(cores), n_distinct(cores$core_id), sum(cores$bd_estimated, na.rm = TRUE)))
  cores
}
