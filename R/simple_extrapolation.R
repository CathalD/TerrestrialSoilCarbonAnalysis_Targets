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

  # Explicit per-stratum areas (hectares) — e.g. from a land-cover summary where
  # strata are raster classes rather than vector polygons. Used directly for
  # absolute totals when present (takes precedence over AOI polygon geometry).
  strata_areas <- cfg$STRATUM_AREAS
  if (!is.null(strata_areas) && length(strata_areas) > 0) {
    area_df <- data.frame(stratum = names(strata_areas),
                          area_m2 = as.numeric(strata_areas) * 10000)
    per_stratum <- per_stratum |>
      left_join(area_df, by = "stratum") |>
      mutate(total_stock_kg  = stock_density_kg_m2 * area_m2,
             total_stock_MgC = total_stock_kg / 1000)
    unmatched <- per_stratum$stratum[is.na(per_stratum$area_m2)]
    if (length(unmatched) > 0)
      warning(sprintf("[step2] STRATUM_AREAS has no area for: %s (their totals are NA).",
                      paste(unmatched, collapse = ", ")))
    message(sprintf("[step2] Absolute totals from STRATUM_AREAS: %.1f ha across %d strata.",
                    sum(area_df$area_m2, na.rm = TRUE) / 10000, nrow(area_df)))
    return(per_stratum)
  }

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

# ── Thematic per-stratum stock map (no covariates needed) ─────────────────────
# Simple spatial extrapolation: paint each AOI polygon with the mean carbon stock
# of its stratum (averaged across that stratum's cores). Needs only the AOI
# polygons + a stratum field — NO remote-sensing covariate raster.
#
# Assumes a uniform stock within each stratum polygon (the simplest possible
# spatial model). Returns:
#   list(topsoil = <ggplot|NULL>, full_profile = <ggplot|NULL>, data = <df>)
map_strata_stocks <- function(stratum_summary, cores_harmonized, cfg) {
  suppressPackageStartupMessages({ library(dplyr); library(ggplot2) })

  di <- cfg$DEPTH_INTERVALS
  topsoil_mids <- if (!is.null(di)) di$depth_midpoint[di$depth_bottom <= 30] else c(7.5, 22.5)

  per_stratum <- stratum_summary |>
    group_by(stratum) |>
    summarise(
      n_cores       = max(n_cores),
      topsoil_kg_m2 = sum(mean_stock[depth_cm_midpoint %in% topsoil_mids], na.rm = TRUE),
      full_kg_m2    = sum(mean_stock, na.rm = TRUE),
      .groups = "drop"
    ) |>
    mutate(topsoil_MgC_ha = topsoil_kg_m2 * 10,
           full_MgC_ha    = full_kg_m2 * 10)

  aoi_path      <- cfg$AOI_FILE
  stratum_field <- cfg$AOI_STRATUM_FIELD
  has_aoi       <- !is.null(aoi_path) && file.exists(aoi_path)
  no_map        <- list(topsoil = NULL, full_profile = NULL, data = per_stratum)

  base_theme <- function(g) g +
    theme_bw(base_size = 11) +
    theme(axis.title = element_blank(), axis.text = element_blank(),
          axis.ticks = element_blank(), panel.grid = element_blank())

  # ── Case 1: AOI carries per-stratum polygons → choropleth ──────────────────
  if (has_aoi && !is.null(stratum_field)) {
    suppressPackageStartupMessages({ library(sf) })
    aoi <- tryCatch(sf::st_read(aoi_path, quiet = TRUE), error = function(e) NULL)
    if (!is.null(aoi) && stratum_field %in% names(aoi)) {
      aoi_stock <- aoi |>
        mutate(stratum = as.character(.data[[stratum_field]])) |>
        left_join(per_stratum, by = "stratum")
      # Reproject to local UTM so geometry is planar (accurate labels, no warning).
      aoi_stock <- tryCatch({
        if (!is.na(sf::st_crs(aoi_stock)) && isTRUE(sf::st_is_longlat(aoi_stock))) {
          bb <- sf::st_bbox(aoi_stock)
          lon_c <- as.numeric((bb["xmin"] + bb["xmax"]) / 2)
          lat_c <- as.numeric((bb["ymin"] + bb["ymax"]) / 2)
          sf::st_transform(aoi_stock,
            (if (lat_c >= 0) 32600 else 32700) + floor((lon_c + 180) / 6) + 1)
        } else aoi_stock
      }, error = function(e) aoi_stock)
      mk <- function(fill_col, title) {
        base_theme(
          ggplot(aoi_stock) +
            geom_sf(aes(fill = .data[[fill_col]]), colour = "grey25", linewidth = 0.2) +
            geom_sf_label(aes(label = stratum), size = 2.4, colour = "grey10",
                          fill = "white", alpha = 0.7, linewidth = 0) +
            scale_fill_gradient(name = "kg C/m²", low = "#f6e0c5", high = "#7f3b08",
                                na.value = "grey85")
        ) + labs(title = title,
                 subtitle = "Per-stratum mean across cores, painted onto the area of interest")
      }
      message("[step2-map] Choropleth thematic map built from AOI polygons.")
      return(list(topsoil = mk("topsoil_kg_m2", "Mean topsoil carbon stock (0–30 cm)"),
                  full_profile = mk("full_kg_m2", "Mean full-profile carbon stock (0–100 cm)"),
                  data = per_stratum))
    }
  }

  # ── Case 2: no per-stratum polygons → sampling plots over the AOI ───────────
  # Colour each plot by its own carbon stock; show the AOI outline for context.
  if (is.null(cores_harmonized) ||
      !all(c("longitude", "latitude") %in% names(cores_harmonized))) {
    message("[step2-map] No per-stratum polygons and no plot coordinates — skipping map.")
    return(no_map)
  }
  per_core <- cores_harmonized |>
    group_by(core_id, stratum, longitude, latitude) |>
    summarise(
      topsoil_kg_m2 = sum(carbon_stock_kg_m2[depth_cm_midpoint %in% topsoil_mids], na.rm = TRUE),
      full_kg_m2    = sum(carbon_stock_kg_m2, na.rm = TRUE),
      .groups = "drop"
    )

  suppressPackageStartupMessages({ library(sf) })
  pts <- sf::st_as_sf(per_core, coords = c("longitude", "latitude"), crs = 4326)
  aoi_outline <- NULL
  if (has_aoi) {
    aoi_outline <- tryCatch(sf::st_read(aoi_path, quiet = TRUE), error = function(e) NULL)
    if (!is.null(aoi_outline) && !is.na(sf::st_crs(aoi_outline)))
      pts <- sf::st_transform(pts, sf::st_crs(aoi_outline))
  }
  mk_pts <- function(stock_col, title) {
    g <- ggplot()
    if (!is.null(aoi_outline))
      g <- g + geom_sf(data = aoi_outline, fill = "grey95", colour = "grey50", linewidth = 0.3)
    g <- g + geom_sf(data = pts, aes(colour = .data[[stock_col]]), size = 3, alpha = 0.9) +
      scale_colour_gradient(name = "kg C/m²", low = "#d9b38c", high = "#7f3b08")
    base_theme(g) +
      labs(title = title, subtitle = "Sampling plots coloured by carbon stock")
  }
  message(sprintf("[step2-map] Point thematic map built for %d plots over the AOI.",
                  nrow(per_core)))
  list(
    topsoil      = mk_pts("topsoil_kg_m2", "Topsoil carbon stock by plot (0–30 cm)"),
    full_profile = mk_pts("full_kg_m2",    "Full-profile carbon stock by plot (0–100 cm)"),
    data         = per_stratum
  )
}
