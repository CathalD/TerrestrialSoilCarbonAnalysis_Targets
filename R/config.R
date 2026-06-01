# R/config.R
# ============================================================================
# PURPOSE: Wrap soil_carbon_config.R into a function that returns a list.
#
# HOW targets USES THIS:
#   In _targets.R:
#     tar_target(cfg, load_config())
#   targets calls load_config() once, stores the result as "cfg", and passes
#   it to any downstream target that lists cfg as an argument.
#
# ACCESSING VALUES:
#   cfg$PROJECT_NAME
#   cfg$DEPTH_MIDPOINTS        # c(7.5, 22.5, 45, 80)
#   cfg$DEPTH_INTERVALS        # data.frame with depth_top/bottom/midpoint/thickness_cm
#   cfg$BD_DEFAULTS            # list(F=0.90, GL=1.20, CL=1.30)
#   cfg$QC_SOC_MIN / cfg$QC_SOC_MAX
#   cfg$QC_BD_MIN  / cfg$QC_BD_MAX
# ============================================================================
load_config <- function(config_path = "soil_carbon_config.R") {
  env <- new.env(parent = baseenv())
  source(config_path, local = env)
  as.list(env)
}
