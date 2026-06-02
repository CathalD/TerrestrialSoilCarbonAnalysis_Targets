# =============================================================================
# R/preanalysis/gee_covariates.R
# GEE covariate extraction for terrestrial soil carbon mapping.
#
# Produces the canonical 28-band terrestrial stack:
#   Group 1 — Topography & Terrain (6):
#     elevation_m, slope, aspect, twi, tpi, curvature
#   Group 2 — Sentinel-1 SAR (3):
#     VV_mean, VH_mean, VVVH_ratio
#   Group 3 — Sentinel-2 Optical Raw (9):
#     B, G, R, B5, B6, B7, NIR, SWIR1, SWIR2
#   Group 4 — Sentinel-2 Derived Indices (6):
#     NDVI_median, EVI_median, LSWI_median, SAVI_median, NDMI_median, BSI_median
#   Group 5 — Climate (4):
#     MAT_C, MAP_mm, PET_mm, aridity_index
#
# Literature justification:
#   NDVI/EVI, climate (MAT/MAP), and terrain (TWI/slope) are the primary
#   predictors of SOC globally (Hengl et al. 2017; Guo et al. 2022).
#   SAR VV/VH captures soil moisture and residue cover (Paloscia et al. 2013).
#   PET and aridity index capture the water balance controlling decomposition
#   rate (a primary climate driver of SOC; FAO SOC Mapping Cookbook 2019).
#   BSI and NDMI differentiate bare mineral soils from vegetated surfaces.
# =============================================================================

# Canonical band order — must match TerrestrialSOC_AOICovariateAnalysis.js
# and TerrestrialSOC_GlobalCoreCovariate_Extraction notebook
CANONICAL_BANDS <- c(
  # Group 1 — Topography
  "elevation_m", "slope", "aspect", "twi", "tpi", "curvature",
  # Group 2 — SAR
  "VV_mean", "VH_mean", "VVVH_ratio",
  # Group 3 — S2 raw reflectance (incl. Red-Edge for canopy structure)
  "B", "G", "R", "B5", "B6", "B7", "NIR", "SWIR1", "SWIR2",
  # Group 4 — S2 derived indices
  "NDVI_median", "EVI_median", "LSWI_median",
  "SAVI_median", "NDMI_median", "BSI_median",
  # Group 5 — Climate
  "MAT_C", "MAP_mm", "PET_mm", "aridity_index"
)
stopifnot(length(CANONICAL_BANDS) == 28L)

.GEE_SYSTEM_COLS <- c("system:index", ".geo", "first")

# ── Date ranges ───────────────────────────────────────────────────────────────
.S2_START  <- "2020-01-01"
.S2_END    <- "2023-12-31"
.SAR_START <- "2020-01-01"
.SAR_END   <- "2023-12-31"
.TC_START  <- "2000-01-01"
.TC_END    <- "2022-12-31"

# ── S2 extraction parameters ─────────────────────────────────────────────────
.S2_MAX_CLOUD    <- 20L
.S2_BUFFER_M     <- 5000L
.S2_SCALE        <- 30L
.TILE_SCALE      <- 8L
# Include Red-Edge bands (B5/B6/B7) for canopy structure estimation.
.S2_BANDS_FULL   <- c("B2", "B3", "B4", "B5", "B6", "B7", "B8", "B11", "B12", "QA60")


# =============================================================================
# INTERNAL HELPERS — image stack builders
# =============================================================================

.build_topo_stack <- function() {
  dem        <- ee$Image("NASA/NASADEM_HGT/001")$select("elevation")
  elevation  <- dem$rename("elevation_m")
  slope      <- ee$Terrain$slope(dem)$rename("slope")
  aspect     <- ee$Terrain$aspect(dem)$rename("aspect")

  # TWI: ln(upslope_area / tan(slope))
  slope_rad <- ee$Terrain$slope(dem)$multiply(pi / 180)
  tan_slope <- slope_rad$tan()$max(0.001)
  contrib   <- dem$gte(-9999)$unmask(0L)$
    reduceNeighborhood(
      reducer = ee$Reducer$sum(),
      kernel  = ee$Kernel$circle(radius = 20, units = "pixels")
    )$max(1)
  twi <- contrib$divide(tan_slope)$log()$rename("twi")

  # TPI: elevation minus 300 m focal mean (positive = ridge, negative = hollow)
  focal_mean <- dem$focalMean(list(radius = 300, units = "meters"))
  tpi        <- dem$subtract(focal_mean)$rename("tpi")

  # Curvature: second derivative of elevation — positive = convex, negative = concave
  # Approximated as standard deviation of slope within a small neighbourhood.
  # Positive curvature (convex hillslopes) = faster drainage, lower SOC.
  # Negative curvature (concave hollows) = water accumulation, higher SOC.
  curvature <- ee$Terrain$slope(dem)$
    reduceNeighborhood(
      reducer = ee$Reducer$stdDev(),
      kernel  = ee$Kernel$circle(radius = 3, units = "pixels")
    )$rename("curvature")

  elevation$addBands(slope)$addBands(aspect)$
    addBands(twi)$addBands(tpi)$addBands(curvature)
}


.build_sar_stack <- function() {
  s1_col <- ee$ImageCollection("COPERNICUS/S1_GRD")$
    filterDate(.SAR_START, .SAR_END)$
    filter(ee$Filter$listContains("transmitterReceiverPolarisation", "VV"))$
    filter(ee$Filter$listContains("transmitterReceiverPolarisation", "VH"))$
    filter(ee$Filter$eq("instrumentMode", "IW"))$
    map(function(img) img$updateMask(img$select("VV")$gt(-30)))

  s1_mean <- s1_col$mean()
  vv      <- s1_mean$select("VV")$rename("VV_mean")
  vh      <- s1_mean$select("VH")$rename("VH_mean")
  vvvh    <- s1_mean$select("VV")$subtract(s1_mean$select("VH"))$rename("VVVH_ratio")

  vv$addBands(vh)$addBands(vvvh)
}


.build_climate_stack <- function() {
  terra_mean <- ee$ImageCollection("IDAHO_EPSCOR/TERRACLIMATE")$
    filterDate(.TC_START, .TC_END)$
    select(c("tmmn", "tmmx", "pr", "pet"))$
    mean()

  # MAT (°C): raw units are °C × 10
  mat_img <- terra_mean$expression(
    "((tmmn + tmmx) / 2.0) / 10.0",
    list("tmmn" = terra_mean$select("tmmn"),
         "tmmx" = terra_mean$select("tmmx"))
  )$rename("MAT_C")

  # MAP (mm/year): raw is mm/month → × 12
  map_img <- terra_mean$select("pr")$multiply(12)$rename("MAP_mm")

  # PET (mm/year): raw is mm/month × 0.1 → × 12 × 0.1
  pet_img <- terra_mean$select("pet")$multiply(12)$multiply(0.1)$rename("PET_mm")

  # Aridity index (dimensionless): MAP / PET — values < 0.5 = arid/semi-arid
  aridity_img <- map_img$divide(pet_img$max(1))$rename("aridity_index")

  mat_img$addBands(map_img)$addBands(pet_img)$addBands(aridity_img)
}


# Per-batch S2 median for terrestrial sites.
# Growing season filter (May–Sep) reflects peak canopy SOC proxy signal
# for temperate/boreal Canada. Adjust for tropical AOIs.
.build_s2_median <- function(region) {
  process <- function(image) {
    qa         <- image$select("QA60")
    cloud_mask <- qa$bitwiseAnd(1024L)$eq(0L)$And(qa$bitwiseAnd(2048L)$eq(0L))
    image$divide(10000)$updateMask(cloud_mask)
  }

  ee$ImageCollection("COPERNICUS/S2_SR_HARMONIZED")$
    filterDate(.S2_START, .S2_END)$
    filterBounds(region)$
    filter(ee$Filter$lt("CLOUDY_PIXEL_PERCENTAGE", .S2_MAX_CLOUD))$
    filter(ee$Filter$calendarRange(5, 9, "month"))$   # growing season
    select(.S2_BANDS_FULL)$
    map(process)$
    median()
}


# 9 raw reflectance bands including Red-Edge (B5/B6/B7)
.s2_select_raw <- function(s2) {
  s2$select("B2")$rename("B")$
    addBands(s2$select("B3")$rename("G"))$
    addBands(s2$select("B4")$rename("R"))$
    addBands(s2$select("B5"))$   # Red-Edge 705 nm
    addBands(s2$select("B6"))$   # Red-Edge 740 nm
    addBands(s2$select("B7"))$   # Red-Edge 783 nm
    addBands(s2$select("B8")$rename("NIR"))$
    addBands(s2$select("B11")$rename("SWIR1"))$
    addBands(s2$select("B12")$rename("SWIR2"))
}


# 6 derived indices relevant to terrestrial SOC prediction
.s2_select_derived <- function(s2) {
  # NDVI: green vegetation density (strong SOC proxy)
  ndvi <- s2$normalizedDifference(c("B8", "B4"))$rename("NDVI_median")

  # EVI: atmosphere-corrected vegetation index; less saturation than NDVI
  evi <- s2$expression(
    "2.5 * ((NIR - RED) / (NIR + 6*RED - 7.5*BLUE + 1))",
    list("NIR"  = s2$select("B8"),
         "RED"  = s2$select("B4"),
         "BLUE" = s2$select("B2"))
  )$rename("EVI_median")

  # LSWI: land surface water index — soil/canopy moisture
  lswi <- s2$normalizedDifference(c("B8", "B11"))$rename("LSWI_median")

  # SAVI: soil-adjusted VI — reduces soil background interference
  savi <- s2$expression(
    "((NIR - RED) / (NIR + RED + 0.5)) * 1.5",
    list("NIR" = s2$select("B8"), "RED" = s2$select("B4"))
  )$rename("SAVI_median")

  # NDMI: normalised difference moisture index — plant water stress proxy
  ndmi <- s2$normalizedDifference(c("B8", "B11"))$rename("NDMI_median")

  # BSI: bare soil index — exposed mineral soils / low vegetation cover
  bsi <- s2$expression(
    "((SWIR1 + RED) - (NIR + BLUE)) / ((SWIR1 + RED) + (NIR + BLUE))",
    list("SWIR1" = s2$select("B11"),
         "RED"   = s2$select("B4"),
         "NIR"   = s2$select("B8"),
         "BLUE"  = s2$select("B2"))
  )$rename("BSI_median")

  ndvi$addBands(evi)$addBands(lswi)$addBands(savi)$addBands(ndmi)$addBands(bsi)
}


# =============================================================================
# INTERNAL HELPERS — batch extraction engine
# =============================================================================

.df_to_ee_fc <- function(df) {
  features <- lapply(seq_len(nrow(df)), function(i) {
    row  <- df[i, ]
    geom <- ee$Geometry$Point(c(as.numeric(row$longitude), as.numeric(row$latitude)))
    ee$Feature(geom, list(
      profile_id = as.character(row$profile_id),
      dataset    = as.character(row$dataset)
    ))
  })
  ee$FeatureCollection(features)
}


.ee_fc_result_to_df <- function(result_fc, name, use_drive = FALSE) {
  suppressPackageStartupMessages(library(dplyr))

  if (use_drive) {
    task_name <- paste0("rgee_", gsub("[^a-zA-Z0-9]", "_", substr(name, 1L, 40L)))
    task <- rgee::ee_table_to_drive(
      collection  = result_fc,
      description = task_name,
      fileFormat  = "CSV",
      folder      = "rgee_exports"
    )
    task$start()
    message(sprintf("  [Drive] task '%s' submitted — waiting...", task_name))
    rgee::ee_monitoring(task, max_attempts = 200L, quiet = TRUE)

    local_file <- tempfile(fileext = ".csv")
    rgee::ee_drive_to_local(task, dsn = local_file, quiet = TRUE)
    df <- readr::read_csv(local_file, show_col_types = FALSE)
    df <- df[, setdiff(names(df), .GEE_SYSTEM_COLS), drop = FALSE]
    return(df)
  }

  data <- result_fc$getInfo()$features
  if (length(data) == 0L) return(data.frame())
  rows <- lapply(data, function(f) {
    props <- f$properties
    props <- props[setdiff(names(props), .GEE_SYSTEM_COLS)]
    props <- lapply(props, function(v) if (is.null(v)) NA else v)
    as.data.frame(props, stringsAsFactors = FALSE)
  })
  dplyr::bind_rows(rows)
}


.extract_batch <- function(image, profiles_df, name,
                            batch_size = 100L, scale = 30L, use_drive = FALSE) {
  suppressPackageStartupMessages(library(dplyr))

  n         <- nrow(profiles_df)
  n_batches <- ceiling(n / batch_size)
  all_rows  <- list()
  n_failed  <- 0L

  message(sprintf("[GEE] Extracting %s (%d pts, batch=%d, scale=%dm, tileScale=%d)",
                  name, n, batch_size, scale, .TILE_SCALE))

  for (i in seq(1L, n, by = batch_size)) {
    end_idx   <- min(i + batch_size - 1L, n)
    batch_df  <- profiles_df[i:end_idx, ]
    fc        <- .df_to_ee_fc(batch_df)
    batch_num <- ceiling(i / batch_size)

    tryCatch({
      result_fc <- image$reduceRegions(
        collection = fc,
        reducer    = ee$Reducer$first(),
        scale      = scale,
        tileScale  = .TILE_SCALE
      )
      batch_df_out <- .ee_fc_result_to_df(result_fc, name, use_drive)
      all_rows <- c(all_rows, list(batch_df_out))

      if (batch_num %% 10L == 0L || batch_num == n_batches)
        message(sprintf("  Batch %d/%d OK  (%d rows so far)",
                        batch_num, n_batches, sum(vapply(all_rows, nrow, 0L))))
    }, error = function(e) {
      n_failed <<- n_failed + 1L
      message(sprintf("  Batch %d/%d FAILED: %s", batch_num, n_batches, conditionMessage(e)))
    })
  }

  message(sprintf("[GEE] %s complete — %d rows, %d batches failed",
                  name, sum(vapply(all_rows, nrow, 0L)), n_failed))

  if (length(all_rows) == 0L) return(data.frame())
  dplyr::bind_rows(all_rows)
}


.BATCH_TIMEOUT_S     <- 300L
.INTER_BATCH_SLEEP_S <- 1L

.extract_batch_s2_all <- function(profiles_df, batch_size = 5L,
                                   scale = .S2_SCALE, use_drive = FALSE) {
  suppressPackageStartupMessages(library(dplyr))

  profiles_df <- profiles_df[order(profiles_df$longitude, profiles_df$latitude), ]

  n         <- nrow(profiles_df)
  n_batches <- ceiling(n / batch_size)
  all_rows  <- list()
  n_failed  <- 0L

  message("[GEE] Extracting S2 all bands — raw (9) + derived (6) combined")
  message(sprintf("      %d pts | batch=%d | scale=%dm | tileScale=%d | buffer=%dm | timeout=%ds",
                  n, batch_size, scale, .TILE_SCALE, .S2_BUFFER_M, .BATCH_TIMEOUT_S))

  for (i in seq(1L, n, by = batch_size)) {
    end_idx   <- min(i + batch_size - 1L, n)
    batch_df  <- profiles_df[i:end_idx, ]
    fc        <- .df_to_ee_fc(batch_df)
    batch_num <- ceiling(i / batch_size)

    setTimeLimit(elapsed = .BATCH_TIMEOUT_S, transient = TRUE)
    tryCatch({
      region   <- fc$geometry()$bounds()$buffer(.S2_BUFFER_M)
      s2_local <- .build_s2_median(region)

      img <- .s2_select_raw(s2_local)$addBands(.s2_select_derived(s2_local))

      result_fc <- img$reduceRegions(
        collection = fc,
        reducer    = ee$Reducer$first(),
        scale      = scale,
        tileScale  = .TILE_SCALE
      )
      batch_df_out <- .ee_fc_result_to_df(result_fc, "S2 all bands", use_drive)
      all_rows <- c(all_rows, list(batch_df_out))

      if (batch_num %% 10L == 0L || batch_num == n_batches)
        message(sprintf("  Batch %d/%d OK  (%d rows so far)",
                        batch_num, n_batches, sum(vapply(all_rows, nrow, 0L))))
    }, error = function(e) {
      n_failed <<- n_failed + 1L
      label <- if (grepl("elapsed time limit", conditionMessage(e), ignore.case = TRUE))
        sprintf("TIMEOUT (>%ds)", .BATCH_TIMEOUT_S)
      else
        conditionMessage(e)
      message(sprintf("  Batch %d/%d FAILED: %s", batch_num, n_batches, label))
    })

    Sys.sleep(.INTER_BATCH_SLEEP_S)
  }

  message(sprintf("[GEE] S2 all bands complete — %d rows, %d batches failed",
                  sum(vapply(all_rows, nrow, 0L)), n_failed))

  if (length(all_rows) == 0L) return(data.frame())
  dplyr::bind_rows(all_rows)
}


# =============================================================================
# PUBLIC API
# =============================================================================

extract_topo <- function(profiles_df, gee_project = NULL, use_drive = FALSE) {
  suppressPackageStartupMessages(library(rgee))
  initialize_gee(gee_project)
  message("[GEE] Building terrestrial topography stack (6 bands)...")
  stack <- .build_topo_stack()
  .extract_batch(stack, profiles_df, "Topography (6 bands)",
                 batch_size = 500L, scale = 30L, use_drive = use_drive)
}

extract_sar <- function(profiles_df, gee_project = NULL, use_drive = FALSE) {
  suppressPackageStartupMessages(library(rgee))
  initialize_gee(gee_project)
  message("[GEE] Building Sentinel-1 SAR stack...")
  stack <- .build_sar_stack()
  .extract_batch(stack, profiles_df, "Sentinel-1 SAR (3 bands)",
                 batch_size = 100L, scale = 30L, use_drive = use_drive)
}

extract_s2_all <- function(profiles_df, gee_project = NULL, use_drive = FALSE) {
  suppressPackageStartupMessages(library(rgee))
  initialize_gee(gee_project)
  .extract_batch_s2_all(profiles_df, batch_size = 5L,
                         scale = .S2_SCALE, use_drive = use_drive)
}

extract_climate <- function(profiles_df, gee_project = NULL, use_drive = FALSE) {
  suppressPackageStartupMessages(library(rgee))
  initialize_gee(gee_project)
  message(sprintf("[GEE] Building TerraClimate stack (%s–%s, MAT/MAP/PET/AI)...",
                  substr(.TC_START, 1, 4), substr(.TC_END, 1, 4)))
  stack <- .build_climate_stack()
  .extract_batch(stack, profiles_df,
                 sprintf("TerraClimate MAT/MAP/PET/AI (%s–%s)",
                         substr(.TC_START, 1, 4), substr(.TC_END, 1, 4)),
                 batch_size = 500L, scale = 4000L, use_drive = use_drive)
}


# =============================================================================
# combine_covariates()
# =============================================================================
combine_covariates <- function(profiles_df, topo, sar, s2, climate) {
  suppressPackageStartupMessages(library(dplyr))

  .merge_gee <- function(main, sub) {
    if (is.null(sub) || !is.data.frame(sub) || nrow(sub) == 0L) return(main)
    sub <- sub |>
      mutate(profile_id = as.character(profile_id)) |>
      select(-any_of(c(.GEE_SYSTEM_COLS, "dataset")))
    dplyr::left_join(main, sub, by = "profile_id")
  }

  result <- profiles_df |>
    mutate(profile_id = as.character(profile_id))

  for (df in list(climate, topo, sar, s2)) {
    result <- .merge_gee(result, df)
  }

  missing <- setdiff(CANONICAL_BANDS, names(result))
  if (length(missing) > 0L) {
    warning(sprintf("[covariates] %d canonical band(s) missing (extraction failed): %s",
                    length(missing), paste(missing, collapse = ", ")))
    for (b in missing) result[[b]] <- NA_real_
  }

  # Drop any coastal or legacy bands that may appear in older global data files
  legacy_bands <- c(
    "elevationRelMHW", "tidal_flat_prob", "coastal_dist_m", "dist_to_channel_m",
    "mNDWI_median", "tidal_wetness", "EVI_median_old",
    "sg_soc_0_30cm", "sg_soc_30_100cm", "sg_soc_0_100cm", "first"
  )
  result <- select(result, -any_of(legacy_bands))

  meta_cols <- setdiff(names(result), CANONICAL_BANDS)
  result[, c(meta_cols, CANONICAL_BANDS)]
}


# =============================================================================
# write_covariates_csv()
# =============================================================================
write_covariates_csv <- function(global_covariates, path) {
  suppressPackageStartupMessages(library(readr))

  n_profiles   <- nrow(global_covariates)
  n_cols       <- ncol(global_covariates)
  n_complete   <- sum(complete.cases(global_covariates[, CANONICAL_BANDS]))
  pct_complete <- round(100 * n_complete / n_profiles, 1)

  readr::write_csv(global_covariates, path)

  message(sprintf("[covariates] Saved: %s", path))
  message(sprintf("[covariates] %d profiles × %d cols | %d/%d (%.1f%%) with complete covariates",
                  n_profiles, n_cols, n_complete, n_profiles, pct_complete))

  for (band in CANONICAL_BANDS) {
    na_rate <- mean(is.na(global_covariates[[band]]))
    if (na_rate > 0.05)
      message(sprintf("  warning: %s: %.1f%% NA (check GEE extraction)", band, 100 * na_rate))
  }

  path
}
