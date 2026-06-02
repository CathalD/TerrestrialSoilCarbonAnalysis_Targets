# R/depth_harmonization.R
# ============================================================================
# PURPOSE: Harmonize raw depth profiles to standard analysis depths.
#
# METHOD: Hybrid monotone Hermite spline (monoH.FC) + exponential decay extrapolation.
#         (A mass-preserving / equal-area spline is a recommended future upgrade.)
#
# DEFAULT DEPTHS (midpoints): 7.5, 22.5, 45, 80 cm
# LAYER THICKNESSES:           15,   15, 30, 40 cm
# — aggregates to 0–30 cm (topsoil) and 0–100 cm (full profile)
#
# Depths are read from cfg$DEPTH_MIDPOINTS / cfg$DEPTH_INTERVALS.
#
# FORMULA:
#   carbon_stock_kg_m2 = SOC(g/kg) × BD(g/cm³) × thickness(cm) / 100
#
# INPUT:
#   cores_raw — data frame from load_raw_data()
#   cfg       — named list from load_config()
#
# OUTPUT — one row per core × depth interval:
#   core_id, stratum, latitude, longitude,
#   depth_cm_midpoint, thickness_cm,
#   soc_harmonized, bd_harmonized,
#   carbon_stock_kg_m2,
#   is_extrapolated — TRUE if target depth exceeded measured range
#   rmse, r2        — leave-one-layer-out fit diagnostics (honest interpolation error)
#   qa_monotonic    — SOC decreasing with depth (Spearman rho < -0.3)
# ============================================================================
harmonize_depths <- function(cores_raw, cfg) {
  suppressPackageStartupMessages({ library(dplyr) })

  # ── Configuration ─────────────────────────────────────────────────────────
  standard_depths <- cfg$DEPTH_MIDPOINTS %||% c(7.5, 22.5, 45, 80)

  depth_intervals <- cfg$DEPTH_INTERVALS
  thickness <- if (!is.null(depth_intervals)) {
    depth_intervals$thickness_cm
  } else {
    c(15, 15, 30, 40)
  }

  cores_qa <- cores_raw |>
    filter(!is.na(depth_cm), !is.na(soc_g_kg), !is.na(bulk_density_g_cm3)) |>
    arrange(core_id, depth_cm)

  message(sprintf("[harmonization] Processing %d cores...",
                  n_distinct(cores_qa$core_id)))

  # ── Helper: leave-one-layer-out fit diagnostics ──────────────────────────
  # The interpolating spline passes through every observed layer, so in-sample
  # residuals are ~0 and tell us nothing. Leave-one-layer-out refits the spline
  # without each layer and predicts it — an honest interpolation-error estimate.
  # Needs >= 3 layers; returns NA otherwise (r2 may be negative, by design).
  get_diagnostics <- function(core_df) {
    d <- core_df$depth_cm
    y <- core_df$soc_g_kg
    n <- length(d)
    if (n < 3) return(list(rmse = NA_real_, r2 = NA_real_))
    preds <- rep(NA_real_, n)
    for (i in seq_len(n)) {
      fit <- tryCatch(splinefun(d[-i], y[-i], method = "monoH.FC"),
                      error = function(e) NULL)
      if (!is.null(fit)) preds[i] <- fit(d[i])
    }
    ok <- !is.na(preds)
    if (sum(ok) < 2) return(list(rmse = NA_real_, r2 = NA_real_))
    resid  <- y[ok] - preds[ok]
    ss_tot <- sum((y[ok] - mean(y[ok]))^2)
    list(
      rmse = sqrt(mean(resid^2)),
      r2   = if (ss_tot > 0) 1 - sum(resid^2) / ss_tot else NA_real_
    )
  }

  # ── Helper: hybrid spline + decay fit ────────────────────────────────────
  fit_hybrid_profile <- function(depths, values, targets) {
    if (length(depths) < 2) return(rep(NA_real_, length(targets)))
    max_d <- max(depths)
    fn <- tryCatch(splinefun(depths, values, method = "monoH.FC"), error = function(e) NULL)
    if (is.null(fn)) return(rep(NA_real_, length(targets)))
    decay <- NULL
    rho   <- tryCatch(
      cor(depths, values, method = "spearman", use = "complete.obs"),
      error = function(e) NA_real_
    )
    if (!is.na(rho) && rho < -0.3 && length(depths) >= 3)
      try(decay <- lm(log(values + 0.1) ~ depths), silent = TRUE)
    sapply(targets, function(d) {
      if (d <= max_d) {
        fn(d)
      } else if (d > max_d * 2.5) {
        NA_real_
      } else if (!is.null(decay) && coef(decay)[2] < 0) {
        exp(predict(decay, newdata = data.frame(depths = d))) - 0.1
      } else {
        values[which.max(depths)]
      }
    })
  }

  # ── Helper: process one core ──────────────────────────────────────────────
  process_core <- function(core_df) {
    depths   <- core_df$depth_cm
    soc_pred <- fit_hybrid_profile(depths, core_df$soc_g_kg, standard_depths)
    bd_fn   <- tryCatch(
      splinefun(depths, core_df$bulk_density_g_cm3, method = "monoH.FC"),
      error = function(e) NULL
    )
    if (is.null(bd_fn)) return(NULL)
    bd_last <- core_df$bulk_density_g_cm3[which.max(depths)]
    bd_pred <- sapply(standard_depths, function(d) {
      if (d <= max(depths)) bd_fn(d) else bd_last
    })
    diag <- get_diagnostics(core_df)
    data.frame(
      core_id           = core_df$core_id[1],
      stratum           = core_df$stratum[1],
      latitude          = core_df$latitude[1],
      longitude         = core_df$longitude[1],
      depth_cm_midpoint = standard_depths,
      thickness_cm      = thickness,
      soc_harmonized    = pmax(0, soc_pred),
      bd_harmonized     = pmax(0, bd_pred),
      is_extrapolated   = standard_depths > max(depths),
      rmse              = diag$rmse,
      r2                = diag$r2
    )
  }

  # ── Main loop ─────────────────────────────────────────────────────────────
  core_ids <- unique(cores_qa$core_id)
  results  <- vector("list", length(core_ids))
  for (i in seq_along(core_ids)) {
    sub <- cores_qa |> filter(core_id == core_ids[i]) |> arrange(depth_cm)
    if (nrow(sub) < 2) next
    results[[i]] <- tryCatch(process_core(sub), error = function(e) NULL)
  }

  harmonized <- bind_rows(results) |>
    mutate(carbon_stock_kg_m2 = (soc_harmonized * bd_harmonized * thickness_cm) / 100) |>
    filter(!is.na(carbon_stock_kg_m2))

  mono <- harmonized |>
    group_by(core_id) |>
    summarise(
      qa_monotonic = cor(depth_cm_midpoint, soc_harmonized, use = "complete.obs") < -0.3,
      .groups = "drop"
    )

  harmonized <- harmonized |> left_join(mono, by = "core_id")

  message(sprintf("[harmonization] Complete. %d cores.", n_distinct(harmonized$core_id)))
  harmonized
}

`%||%` <- function(a, b) if (!is.null(a)) a else b
