# R/outputs.R
# PURPOSE: Write the raw output files (figures + tables) for the non-spatial
# pipeline to disk, so partners can reuse them directly (copy into reports, GIS,
# spreadsheets) without rendering the HTML.
#
# Layout — organized by report heading:
#   outputs/non-spatial/figures/*.png
#   outputs/non-spatial/tables/*.csv
#
# Returns the vector of written file paths (so it can be a format="file" target).
write_nonspatial_outputs <- function(eda_plots, harmonized_eda, strata_map,
                                     stratum_summary, step2_extrapolation,
                                     out_dir = "outputs/non-spatial") {
  suppressPackageStartupMessages({ library(ggplot2); library(readr) })

  fig_dir <- file.path(out_dir, "figures")
  tab_dir <- file.path(out_dir, "tables")
  dir.create(fig_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(tab_dir, recursive = TRUE, showWarnings = FALSE)

  paths <- character(0)
  save_fig <- function(plot, name, w = 8, h = 5) {
    f <- file.path(fig_dir, name)
    if (is.null(plot)) {                 # remove any stale file from a previous run
      if (file.exists(f)) unlink(f)
      return(invisible())
    }
    ggsave(f, plot, width = w, height = h, dpi = 300, bg = "white")
    paths <<- c(paths, f)
  }
  save_tab <- function(df, name) {
    if (is.null(df) || !is.data.frame(df)) return(invisible())
    f <- file.path(tab_dir, name)
    readr::write_csv(df, f)
    paths <<- c(paths, f)
  }

  # ── Figures ────────────────────────────────────────────────────────────────
  # Raw (pre-harmonization)
  save_fig(eda_plots$spatial_map,    "core_locations.png")
  save_fig(eda_plots$depth_profiles, "raw_soc_depth_profiles.png")
  save_fig(eda_plots$carbon_stocks,  "raw_total_stock_by_stratum.png")
  # Harmonized
  save_fig(harmonized_eda$depth_profiles, "harmonized_stock_depth_profiles.png")
  save_fig(harmonized_eda$carbon_stocks,  "harmonized_total_stock_by_stratum.png")
  # Thematic maps (NULL when no AOI polygon + stratum field)
  save_fig(strata_map$topsoil,      "stock_map_topsoil_0_30cm.png",  w = 7, h = 6)
  save_fig(strata_map$full_profile, "stock_map_full_0_100cm.png",    w = 7, h = 6)

  # ── Tables ───────────────────────────────────────────────────────────────────
  save_tab(stratum_summary,     "stratum_depth_summary.csv")
  save_tab(step2_extrapolation, "per_stratum_stock_and_totals.csv")
  save_tab(strata_map$data,     "per_stratum_stock_summary.csv")

  message(sprintf("[outputs] Wrote %d non-spatial output file(s) to %s/.",
                  length(paths), out_dir))
  paths
}
