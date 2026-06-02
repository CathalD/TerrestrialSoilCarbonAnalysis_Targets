# .Rprofile — loaded automatically when opening this RStudio project
library(targets)
library(tarchetypes)

# First run: create a working config from the tracked template if it's missing.
# soil_carbon_config.R is gitignored, so your site settings never collide with
# `git pull`. Edit your copy freely; soil_carbon_config.example.R stays clean.
if (!file.exists("soil_carbon_config.R") && file.exists("soil_carbon_config.example.R")) {
  file.copy("soil_carbon_config.example.R", "soil_carbon_config.R")
  message("Created soil_carbon_config.R from the example template — edit it for your site.")
}

# Main pipeline (non-spatial: Steps 1–2 + report)
tm   <- function(...) targets::tar_make(...)
tv   <- function()    targets::tar_visnetwork()
tl   <- function(x)  targets::tar_load(!!rlang::ensym(x))
tr   <- function(x)  targets::tar_read(x)

# RF pipeline (Step 3: spatial prediction maps)
tmrf <- function()   targets::tar_make(script = "_targets_rf.R", store = "_targets_rf")

app  <- function()   shiny::runApp("shiny", launch.browser = TRUE)

message("Shortcuts: tm() = main pipeline | tmrf() = RF spatial maps | app() = setup wizard")
