mod_raster_ui <- function(id) {
  ns <- NS(id)
  tagList(
    div(class = "step-intro",
      h4("Upload your site boundary with strata."),
      p("The GeoJSON defines which areas belong to which stratum and is used to calculate ",
        "area-weighted carbon stock totals (hectares per stratum). ",
        "The satellite covariate raster is optional and only needed for spatial prediction maps (Pipelines 2–5).")
    ),

    # ── Strata Boundary (Primary) ────────────────────────────────────────────
    bslib::card(
      bslib::card_header("Strata Boundary — required for area-weighted carbon totals"),
      bslib::card_body(
        p("Upload a GeoJSON (or GPKG) where each polygon represents one stratum. ",
          "The app will automatically find the column whose values match the stratum codes ",
          "you entered in Step 1."),

        checkboxInput(ns("skip_strata"),
          "Skip — report carbon density (kg C/m²) only, without area-weighted totals",
          value = FALSE),

        conditionalPanel(
          condition = paste0("!input['", ns("skip_strata"), "']"),
          div(class = "mt-3",
            fileInput(ns("strata_file"), NULL,
              accept      = c(".geojson", ".json", ".gpkg", ".zip"),
              buttonLabel = "Upload strata file",
              placeholder = "site_strata.geojson"),
            uiOutput(ns("detection_status")),
            uiOutput(ns("strata_area_ui"))
          )
        )
      )
    ),

    # ── Covariate Raster (Optional) ──────────────────────────────────────────
    bslib::card(
      bslib::card_header("Covariate Raster — optional, for spatial prediction maps"),
      bslib::card_body(
        checkboxInput(ns("skip_raster"),
          "Skip — run non-spatial analysis only (recommended for MVP)",
          value = TRUE),

        conditionalPanel(
          condition = paste0("!input['", ns("skip_raster"), "']"),
          div(class = "mt-3",
            p("Place your GEE covariate .tif in ",
              code("Pre-Analysis Data Preparation/covariates/"),
              " then enter the filename below."),
            div(class = "row g-2 align-items-end",
              div(class = "col",
                textInput(ns("raster_name"), NULL,
                  placeholder = "e.g. TerrestrialSOC_Covariate_Snapshot_25m_2020_2023.tif")
              ),
              div(class = "col-auto",
                actionButton(ns("check_raster"), "Check file",
                  class = "btn btn-secondary btn-sm")
              )
            ),
            uiOutput(ns("raster_status"))
          )
        )
      )
    )
  )
}

# ── Helper: find which GeoJSON column best matches the valid strata ───────────
# Returns a list of results sorted by match quality (best first).
# Each element: list(col, vals, n_match, n_vals)
detect_stratum_field <- function(sf_obj, valid_strata) {
  geom_col <- attr(sf_obj, "sf_column") %||% "geometry"
  cols <- setdiff(names(sf_obj), geom_col)
  if (length(cols) == 0 || length(valid_strata) == 0) return(list())

  results <- lapply(cols, function(col) {
    vals    <- unique(as.character(sf_obj[[col]]))
    n_match <- length(intersect(valid_strata, vals))
    list(col = col, vals = vals, n_match = n_match, n_vals = length(vals))
  })

  # Best = most strata matched; among ties, fewer unique values preferred
  ord <- order(
    -vapply(results, `[[`, integer(1), "n_match"),
     vapply(results, `[[`, integer(1), "n_vals")
  )
  results[ord]
}

mod_raster_server <- function(id, project_root, setup_state) {
  moduleServer(id, function(input, output, session) {

    raster_info   <- reactiveVal(NULL)
    strata_sf_rv  <- reactiveVal(NULL)
    detected_field <- reactiveVal(NULL)  # column name that matched

    # ── Read GeoJSON on upload ───────────────────────────────────────────────
    observeEvent(input$strata_file, {
      req(input$strata_file)
      result <- tryCatch(
        sf::st_read(input$strata_file$datapath, quiet = TRUE),
        error = function(e) NULL
      )
      strata_sf_rv(result)
    })

    # ── Auto-detect stratum field whenever file or valid_strata changes ──────
    observeEvent(list(strata_sf_rv(), setup_state()$valid_strata), {
      sf_obj        <- strata_sf_rv()
      valid_strata  <- setup_state()$valid_strata

      if (is.null(sf_obj) || length(valid_strata) == 0) {
        detected_field(NULL)
        return()
      }

      results <- detect_stratum_field(sf_obj, valid_strata)
      if (length(results) > 0 && results[[1]]$n_match > 0) {
        detected_field(results[[1]]$col)
      } else {
        detected_field(NULL)
      }
    }, ignoreNULL = FALSE)

    # ── Detection status card ────────────────────────────────────────────────
    output$detection_status <- renderUI({
      # No file yet
      if (is.null(input$strata_file)) return(NULL)

      sf_obj <- strata_sf_rv()

      # File could not be read
      if (is.null(sf_obj)) {
        return(div(class = "alert alert-danger mt-2",
          tags$strong("❌ Could not read file."),
          " Make sure it is a valid GeoJSON or GPKG."))
      }

      valid_strata <- setup_state()$valid_strata

      # Step 1 not finished
      if (length(valid_strata) == 0) {
        return(div(class = "alert alert-warning mt-2",
          "No stratum codes defined yet. Go back to Step 1 and enter your strata codes first."))
      }

      results <- detect_stratum_field(sf_obj, valid_strata)

      # No attribute columns at all
      if (length(results) == 0) {
        return(div(class = "alert alert-danger mt-2",
          tags$strong("❌ No attribute columns found in this file."),
          " The GeoJSON must have at least one property column that identifies the stratum."))
      }

      best <- results[[1]]

      if (best$n_match == length(valid_strata)) {
        # Perfect match
        div(class = "alert alert-success mt-2",
          paste0("✓ All ", length(valid_strata), " strata found in column '",
                 best$col, "'."))

      } else if (best$n_match > 0) {
        # Partial match
        missing_strata <- setdiff(valid_strata, best$vals)
        div(class = "alert alert-warning mt-2",
          tags$strong(paste0("⚠ Partial match — column '", best$col, "'")),
          tags$p(class = "mb-1 mt-1",
            paste0(best$n_match, " of ", length(valid_strata),
                   " strata found. Not found in GeoJSON: "),
            tags$code(paste(missing_strata, collapse = ", ")),
            "."),
          tags$p(class = "mb-0 small text-muted",
            "These strata will not have area-weighted carbon stock totals.")
        )

      } else {
        # No match — show what we looked for and what each column contains
        col_rows <- lapply(results[seq_len(min(4L, length(results)))], function(r) {
          shown <- head(r$vals, 6)
          extra <- if (length(r$vals) > 6) paste0(" … +", length(r$vals) - 6, " more") else ""
          tags$li(
            tags$code(r$col), ": ",
            paste(shown, collapse = ", "), extra
          )
        })

        div(class = "alert alert-danger mt-2",
          tags$strong("❌ Could not detect stratum column."),
          tags$p(class = "mb-1 mt-2",
            "Looking for stratum codes: ",
            tags$code(paste(valid_strata, collapse = ", "))),
          tags$p(class = "mb-1",
            "Values found in GeoJSON columns:"),
          tags$ul(class = "mb-1", col_rows),
          tags$p(class = "mb-0 small text-muted",
            "Check that the stratum codes in Step 1 exactly match the values ",
            "in one of the GeoJSON columns (case-sensitive).")
        )
      }
    })

    # ── Area table ───────────────────────────────────────────────────────────
    output$strata_area_ui <- renderUI({
      sf_obj <- strata_sf_rv()
      field  <- detected_field()
      if (is.null(sf_obj) || is.null(field)) return(NULL)

      area_df <- tryCatch({
        sf_obj$area_m2 <- as.numeric(sf::st_area(sf_obj))
        df <- as.data.frame(sf_obj)[, c(field, "area_m2")]
        names(df)[1] <- "stratum"
        df <- aggregate(area_m2 ~ stratum, data = df, FUN = sum)
        df$area_ha <- round(df$area_m2 / 10000, 2)
        df[order(df$stratum), c("stratum", "area_ha")]
      }, error = function(e) NULL)

      if (is.null(area_df) || nrow(area_df) == 0) return(NULL)

      rows <- lapply(seq_len(nrow(area_df)), function(i) {
        tags$tr(
          tags$td(area_df$stratum[i]),
          tags$td(class = "text-end", paste0(area_df$area_ha[i], " ha"))
        )
      })
      total_ha <- round(sum(area_df$area_ha), 2)

      div(class = "mt-3",
        tags$strong("Area per stratum:"),
        tags$table(class = "table table-sm table-bordered mt-2",
          tags$thead(class = "table-light",
            tags$tr(tags$th("Stratum"), tags$th(class = "text-end", "Area (ha)"))
          ),
          tags$tbody(rows),
          tags$tfoot(
            tags$tr(class = "fw-bold",
              tags$td("Total"),
              tags$td(class = "text-end", paste0(total_ha, " ha"))
            )
          )
        )
      )
    })

    # ── Raster validation ────────────────────────────────────────────────────
    check_raster_file <- function(rname) {
      rname <- trimws(rname %||% "")
      if (nchar(rname) == 0) { raster_info(NULL); return() }

      candidates <- c(
        rname,
        file.path(project_root, rname),
        file.path(project_root, "Pre-Analysis Data Preparation", "covariates", rname)
      )
      found_path <- Find(file.exists, candidates)

      if (is.null(found_path)) {
        raster_info(list(found = FALSE, msg = paste0(
          "File not found. Make sure the .tif is in:\n",
          "  Pre-Analysis Data Preparation/covariates/\n",
          "and the filename matches exactly."
        )))
        return()
      }

      info <- tryCatch({
        suppressPackageStartupMessages(library(terra))
        r <- terra::rast(found_path)
        list(
          found  = TRUE,
          path   = found_path,
          bands  = terra::nlyr(r),
          crs    = tryCatch(terra::crs(r, describe = TRUE)$name, error = function(e) "unknown"),
          res_m  = round(mean(terra::res(r)), 1),
          msg    = paste0("Found: ", basename(found_path))
        )
      }, error = function(e) {
        list(found = FALSE, msg = paste("Could not read raster:", conditionMessage(e)))
      })
      raster_info(info)
    }

    raster_name_d <- debounce(reactive(input$raster_name), 600)
    observeEvent(raster_name_d(), {
      if (!isTRUE(input$skip_raster)) check_raster_file(raster_name_d())
    }, ignoreNULL = FALSE)

    observeEvent(input$check_raster, {
      check_raster_file(input$raster_name)
    })

    output$raster_status <- renderUI({
      info <- raster_info()
      if (is.null(info)) return(helpText("Enter a filename above — it will be validated automatically."))
      if (!info$found) {
        div(class = "alert alert-danger mt-2",
          tags$strong("❌ File not found"), tags$br(),
          tags$small(tags$pre(info$msg))
        )
      } else {
        div(class = "alert alert-success mt-2",
          tags$strong(paste0("✓ ", info$msg)), tags$br(),
          paste0(info$bands, " bands | CRS: ", info$crs,
                 " | Resolution: ~", info$res_m, " m")
        )
      }
    })

    # ── Reactive state (returned to parent) ──────────────────────────────────
    reactive({
      skip_r <- isTRUE(input$skip_raster)
      info   <- raster_info()
      raster_path <- if (!skip_r && !is.null(info) && isTRUE(info$found)) info$path else ""

      skip_strata <- isTRUE(input$skip_strata)
      sf_obj      <- strata_sf_rv()
      field       <- detected_field()
      aoi_source  <- if (!skip_strata && !is.null(input$strata_file)) input$strata_file$datapath else NULL
      aoi_dest    <- if (!is.null(aoi_source)) {
        file.path(project_root, "Pre-Analysis Data Preparation", "data_raw", "aoi_boundary.geojson")
      } else NULL

      strata_info <- NULL
      if (!skip_strata && !is.null(sf_obj) && !is.null(field)) {
        area_df <- tryCatch({
          sf_obj$area_m2 <- as.numeric(sf::st_area(sf_obj))
          df <- as.data.frame(sf_obj)[, c(field, "area_m2")]
          names(df)[1] <- "stratum"
          df <- aggregate(area_m2 ~ stratum, data = df, FUN = sum)
          df$area_ha <- round(df$area_m2 / 10000, 2)
          df[order(df$stratum), ]
        }, error = function(e) NULL)

        if (!is.null(area_df)) {
          strata_info <- list(
            strata        = area_df$stratum,
            area_ha       = area_df$area_ha,
            stratum_field = field,
            has_strata    = TRUE
          )
        }
      }

      list(
        raster_path  = raster_path,
        has_raster   = nchar(raster_path) > 0,
        aoi_source   = aoi_source,
        aoi_dest     = aoi_dest,
        strata_info  = strata_info,
        ready        = TRUE
      )
    })
  })
}
