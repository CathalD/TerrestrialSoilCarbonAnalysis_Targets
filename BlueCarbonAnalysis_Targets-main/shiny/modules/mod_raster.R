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
        p("Upload a GeoJSON file where each polygon (or multi-polygon) represents one stratum. ",
          "The file must have a column that identifies which stratum each polygon belongs to."),

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
            uiOutput(ns("strata_field_ui")),
            uiOutput(ns("strata_area_ui")),
            uiOutput(ns("strata_status"))
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

mod_raster_server <- function(id, project_root) {
  moduleServer(id, function(input, output, session) {

    raster_info  <- reactiveVal(NULL)
    strata_sf_rv <- reactiveVal(NULL)

    # ── Read GeoJSON when uploaded ───────────────────────────────────────────
    observeEvent(input$strata_file, {
      req(input$strata_file)
      if (!requireNamespace("sf", quietly = TRUE)) {
        strata_sf_rv(NULL)
        return()
      }
      result <- tryCatch(
        sf::st_read(input$strata_file$datapath, quiet = TRUE),
        error = function(e) NULL
      )
      strata_sf_rv(result)
    })

    # ── Stratum field selector ───────────────────────────────────────────────
    output$strata_field_ui <- renderUI({
      sf_obj <- strata_sf_rv()
      if (is.null(sf_obj)) return(NULL)
      geom_col <- attr(sf_obj, "sf_column") %||% "geometry"
      cols <- setdiff(names(sf_obj), geom_col)
      if (length(cols) == 0) return(helpText("No attribute columns found in this file."))
      best_guess <- cols[cols %in% c("stratum", "Stratum", "STRATUM",
                                      "class", "Class", "CLASS",
                                      "landuse", "land_use", "LandUse",
                                      "type", "Type", "TYPE")][1]
      selectInput(session$ns("stratum_field"),
        "Which column identifies the strata?",
        choices  = cols,
        selected = if (!is.na(best_guess)) best_guess else cols[1])
    })

    # ── Area preview table ───────────────────────────────────────────────────
    output$strata_area_ui <- renderUI({
      sf_obj <- strata_sf_rv()
      field  <- input$stratum_field
      if (is.null(sf_obj) || is.null(field) || nchar(trimws(field)) == 0) return(NULL)
      if (!(field %in% names(sf_obj))) return(NULL)

      area_df <- tryCatch({
        sf_obj$area_m2 <- as.numeric(sf::st_area(sf_obj))
        df <- as.data.frame(sf_obj)
        df <- df[, c(field, "area_m2")]
        names(df)[1] <- "stratum"
        df <- aggregate(area_m2 ~ stratum, data = df, FUN = sum)
        df$area_ha <- round(df$area_m2 / 10000, 2)
        df[order(df$stratum), c("stratum", "area_ha")]
      }, error = function(e) NULL)

      if (is.null(area_df)) return(NULL)

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

    # ── Upload status ────────────────────────────────────────────────────────
    output$strata_status <- renderUI({
      if (is.null(input$strata_file)) return(NULL)
      sf_obj <- strata_sf_rv()
      if (is.null(sf_obj)) {
        div(class = "alert alert-danger mt-2",
          tags$strong("❌ Could not read file."),
          " Make sure it is a valid GeoJSON, GPKG, or zipped shapefile.")
      } else {
        div(class = "alert alert-success mt-2",
          paste0("✓ ", input$strata_file$name, " — ",
                 nrow(sf_obj), " feature(s) loaded."))
      }
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
      field       <- input$stratum_field %||% ""
      aoi_source  <- if (!skip_strata && !is.null(input$strata_file)) input$strata_file$datapath else NULL
      aoi_dest    <- if (!is.null(aoi_source)) {
        file.path(project_root, "Pre-Analysis Data Preparation", "data_raw", "aoi_boundary.geojson")
      } else NULL

      strata_info <- NULL
      if (!skip_strata && !is.null(sf_obj) && nchar(field) > 0 && field %in% names(sf_obj)) {
        area_df <- tryCatch({
          sf_obj$area_m2 <- as.numeric(sf::st_area(sf_obj))
          df <- as.data.frame(sf_obj)
          df <- df[, c(field, "area_m2")]
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
