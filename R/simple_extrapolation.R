# R/simple_extrapolation.R
# PURPOSE: Step 2a — extrapolate core carbon stocks to the full AOI.
#
# METHOD: Mean stock per stratum (from harmonized depth profiles) x stratum area.
#
# INPUTS:
#   stratum_summary — output of stratum_summary target (one row per stratum x depth)
#   cfg             — named list from load_config()
#
# OUTPUT — data frame with one row per stratum:
#   stratum, n_cores, stock_density_kg_m2, stock_density_MgC_ha
#   + area_m2, total_stock_kg, total_stock_MgC
#     (absolute totals only when an AOI polygon AND a matching stratum field are
#      provided — never fabricated from an equal-area split)
simple_extrapolation <- function(stratum_summary, cfg) {
  suppressPackageStartupMessages({ library(dplyr) })

  # Per-stratum carbon DENSITY: sum of mean stock across depth intervals.
  # Area-independent (kg C/m² and Mg C/ha) — always reported.
  per_stratum <- stratum_summary |>
    group_by(stratum) |>
    summarise(
      n_cores              = max(n_cores),
      stock_density_kg_m2  = sum(mean_stock, na.rm = TRUE),
      stock_density_MgC_ha = sum(mean_stock, na.rm = TRUE) * 10,
      .groups = "drop"
    )

  aoi_path      <- cfg$AOI_FILE
  stratum_field <- cfg$AOI_STRATUM_FIELD

  # Absolute totals (mass) require a per-stratum AREA. We only compute them when
  # an AOI polygon AND a stratum field mapping area to each stratum are provided.
  # We never divide a whole-site area equally across strata: that fabricates a
  # per-stratum breakdown the data cannot support.
  if (is.null(aoi_path) || !file.exists(aoi_path)) {
    message("[step2] No AOI file — reporting per-stratum carbon density only.")
    message("[step2] Provide AOI_FILE + AOI_STRATUM_FIELD in soil_carbon_config.R for absolute totals.")
    return(per_stratum)
  }

  if (is.null(stratum_field)) {
    message("[step2] AOI_STRATUM_FIELD is NULL — area cannot be attributed to individual strata.")
    message("[step2] Reporting per-stratum density only (no fabricated equal-area totals).")
    message("[step2] Set AOI_STRATUM_FIELD to the polygon attribute holding your stratum codes.")
    return(per_stratum)
  }

  suppressPackageStartupMessages({ library(sf) })
  message("[step2] Reading AOI: ", aoi_path)
  aoi <- st_read(aoi_path, quiet = TRUE)

  if (!stratum_field %in% names(aoi)) {
    warning(sprintf(
      "[step2] AOI_STRATUM_FIELD '%s' not found in AOI (columns: %s). Reporting density only.",
      stratum_field, paste(names(aoi), collapse = ", ")))
    return(per_stratum)
  }

  aoi$.area_m2 <- as.numeric(sf::st_area(aoi))
  aoi_areas <- aoi |>
    sf::st_drop_geometry() |>
    group_by(stratum = .data[[stratum_field]]) |>
    summarise(area_m2 = sum(.area_m2), .groups = "drop")

  per_stratum <- per_stratum |>
    left_join(aoi_areas, by = "stratum") |>
    mutate(
      total_stock_kg  = stock_density_kg_m2 * area_m2,
      total_stock_MgC = total_stock_kg / 1000
    )

  unmatched <- per_stratum$stratum[is.na(per_stratum$area_m2)]
  if (length(unmatched) > 0) {
    warning(sprintf(
      "[step2] No AOI area matched these strata (their absolute totals are NA): %s. Check that '%s' values exactly match your stratum codes.",
      paste(unmatched, collapse = ", "), stratum_field))
  }

  message(sprintf(
    "[step2] Extrapolation complete. Matched AOI area: %.1f ha across %d of %d strata.",
    sum(per_stratum$area_m2, na.rm = TRUE) / 10000,
    sum(!is.na(per_stratum$area_m2)), nrow(per_stratum)))

  per_stratum
}
