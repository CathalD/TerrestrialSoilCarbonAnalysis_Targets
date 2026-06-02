# Terrestrial Soil Carbon Analysis — Pipeline Reference

**Language:** R · **Orchestration:** `targets` · **Updated:** June 2026

For setup and usage instructions see the [root README](../README.md).
This document covers the pipeline internals and technical reference.

---

## Pipelines

| Pipeline | Script | Store | Produces |
|----------|--------|-------|----------|
| **1. Core prep** | `_targets.R` | `_targets/` | Depth-harmonized stocks, stratum summaries, HTML report |
| **2. RF spatial** | `_targets_rf.R` | `_targets_rf/` | 25 m carbon stock map |
| **3. Pre-analysis** | `_targets_preanalysis.R` | `_targets_preanalysis/` | GEE covariates at global soil profile locations |
| **4. Wadoux TL** | `_targets_transfer.R` | `_targets_transfer/` | Transfer learning prediction maps |
| **5. Embedding TL** | `_targets_embedding.R` | `_targets_embedding/` | Embedding-weighted prediction maps |

Run order: Pipeline 1 → (optional) Pipeline 2 → Pipeline 3 → Pipelines 4 and/or 5.

---

## Carbon stock formula

```
carbon_stock (kg C/m²) = SOC (g/kg) × BD (g/cm³) × thickness (cm) / 100
```

Where `thickness` is the depth-interval thickness (15, 15, 30, or 40 cm).
Missing bulk density is filled from `BD_DEFAULTS` in `soil_carbon_config.R`
using stratum-specific literature values for Canadian terrestrial ecosystems
(Gregorich et al. 1994; Jandl et al. 2014).

---

## Depth harmonization

Field cores are sampled at irregular intervals. The pipeline harmonizes to
four standard intervals using a hybrid method:

- **Interpolation** (within measured range): monotone Hermite spline (`monoH.FC`)
- **Extrapolation** (below deepest sample): exponential decay where Spearman
  ρ(depth, SOC) < −0.3 and n ≥ 3; constant otherwise
- Extrapolation capped at 2.5× the maximum measured depth

Standard aggregates reported:

| Aggregate | Intervals | Context |
|-----------|-----------|--------------|
| 0–30 cm   | 1 + 2     | Topsoil pool |
| 0–100 cm  | 1 + 2 + 3 + 4 | Full mineral profile |

---

## Transfer learning (Pipelines 4 and 5)

Both pipelines supplement local cores with globally distributed terrestrial soil
profiles from WoSIS, CanPeat, and the Agriculture Canada National Soil Database.
They differ only in how similarity weights are computed.

**Wadoux (Pipeline 4):** A random forest classifier is trained to separate local
from global samples. Predicted probabilities become instance weights — global cores
that look like your site get high weight; dissimilar ones are down-weighted.

**Embedding (Pipeline 5):** Uses Google's `GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL`
64-dimensional foundation model. Cosine similarity between each global core's
embedding and the local AOI mean is raised to the power α = 5 (sharpening), then
normalised. No local classifier is needed.

Both apply the same four-stage model:
1. Weighted global RF at each depth (Stage A)
2. Local bias correction from residuals (Stage B)
3. Bootstrap uncertainty (500 replicates) (Stage C)
4. Raster prediction across the site extent (Stage D)

Leave-one-core-out (LOCO) cross-validation is run at each depth.

---

## Prediction raster bands

Both TL pipelines write one GeoTIFF per depth to `outputs/transfer/` and
`outputs/embedding/`. Each file has four bands:

| Band suffix | Description |
|-------------|-------------|
| `_Global_Prior` | Weighted global RF before bias correction |
| `_Transfer_Final` | Global prior + local bias correction — primary reporting value |
| `_Local_Only` | Stratum mean carbon stock (no spatial model) |
| `_Difference` | Transfer Final minus Global Prior |

Band names follow the pattern `d{midpoint}_{suffix}` with `.` replaced by `_`
(e.g. `d7_5_Transfer_Final`, `d22_5_Transfer_Final`).

---

## Uncertainty (transfer-learning pipelines only)

> **Status:** uncertainty is currently produced **only** for the transfer-learning
> pipelines, and only via the manual post-hoc calculation below. The non-spatial
> (Steps 1–2) and RF spatial (Step 3) pipelines report point estimates; design-based
> and quantile-regression-forest intervals for those pipelines are on the roadmap.

Uncertainty is reported at **90% confidence**:

```r
m   <- targets::tar_read("tl_models", store = "_targets_transfer")$models[["7.5"]]
se  <- sqrt(m$bias_se^2 + m$residual_sd^2)
z90 <- qnorm(0.95)
# For a pixel with prediction p:
lower_90 <- p - z90 * se
upper_90 <- p + z90 * se
```

The lower bound is the conservative reporting value.

---

## Console shortcuts (`.Rprofile`)

```r
tm()     # targets::tar_make()           — run all outdated targets
tv()     # targets::tar_visnetwork()     — visual dependency graph
tl(x)   # targets::tar_load("x")        — load target x into session
tmrf()  # run the RF pipeline
app()   # shiny::runApp("shiny")         — launch the setup app
```

---

## Troubleshooting

```r
# See what will re-run
targets::tar_outdated()

# Inspect errors
targets::tar_meta() |> dplyr::filter(!is.na(error)) |> dplyr::select(name, error)

# Re-run a single target
targets::tar_make(names = "cores_harmonized")

# Non-main stores
targets::tar_make(
  names  = "tl_models",
  script = "_targets_transfer.R",
  store  = "_targets_transfer"
)
```

---

## Scientific references

- Fritsch & Carlson (1980). Monotone piecewise cubic interpolation. *SIAM J. Numer. Anal.*, 17, 238–246. (current depth interpolation)
- Bishop et al. (1999). Equal-area (mass-preserving) splines. *Geoderma*, 91, 27–45. (recommended depth-harmonization upgrade)
- Gregorich, E.G. et al. (1994). Towards a minimum data set to assess soil organic matter quality in agricultural soils. *Canadian Journal of Soil Science*, 74(4), 367–385.
- Wadoux et al. (2021). Knowledge discovery and machine learning in digital soil mapping. *European Journal of Soil Science*, 71, 133–136.
- Hengl et al. (2017). SoilGrids250m. *PLOS ONE*, 12(2), e0169748.
- Landau, W.M. (2021). The targets R package. *Journal of Open Source Software*, 6(57), 2959.
