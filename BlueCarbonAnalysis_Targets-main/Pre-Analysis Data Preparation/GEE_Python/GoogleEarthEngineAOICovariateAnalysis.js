// =================================================================
// Terrestrial Soil Carbon — AOI Covariate Extraction
// =================================================================
// Version: 2.0  (converted from Coastal Blue Carbon v1.0)
//
// PURPOSE:
//   Google Earth Engine script to:
//   1. Define your AOI (draw or provide an asset path)
//   2. Load SoilGrids SOC as a spatial prior
//   3. Build the canonical 28-band terrestrial covariate stack
//   4. Export covariate raster + Google Satellite Embedding to Drive
//   5. Generate stratified soil sampling points (SOC uncertainty-based)
//   6. Export reports and sampling point files
//
// CANONICAL COVARIATE STACK — 28 bands (matches R/preanalysis/gee_covariates.R):
//   Group 1 — Topography & Terrain (6):
//     elevation_m, slope, aspect, twi, tpi, curvature
//   Group 2 — Sentinel-1 SAR (3):
//     VV_mean, VH_mean, VVVH_ratio
//   Group 3 — Sentinel-2 Optical Raw (9):
//     B, G, R, B5, B6, B7, NIR, SWIR1, SWIR2
//   Group 4 — Sentinel-2 Derived Indices (6):
//     NDVI_median, EVI_median, LSWI_median, SAVI_median, NDMI_median, BSI_median
//   Group 5 — Climate (4):
//     MAT_C, MAP_mm, PET_mm, aridity_index
//
// OPTIONAL PRIORS (exported separately — not in canonical 28 bands):
//   SoilGrids SOC (3): sg_soc_0_30cm, sg_soc_30_100cm, sg_soc_0_100cm
//   SoilGrids Clay (1): sg_clay_0_30cm (stabilises SOC — useful as covariate)
//
// WORKFLOW:
//   Run steps ①–⑥ in order using the buttons in the side panel.
// =================================================================


// ─────────────────────────────────────────────────────────────────
// SECTION A — CONFIGURATION
// ─────────────────────────────────────────────────────────────────

var AOI_ASSET = null;  // Set to GEE asset path or leave null to draw

// ── Export settings ──────────────────────────────────────────────
var EXPORT_CRS    = 'EPSG:3347';              // Canada Albers Equal Area
var EXPORT_SCALE  = 25;                       // metres — covariate raster
var EMBED_SCALE   = 10;                       // metres — Google Embedding
var EXPORT_FOLDER = 'TerrestrialSOC_GEE';     // Google Drive folder
var PROJECT_YEAR  = '2020_2023';

// ── Sentinel-2 date range & cloud threshold ───────────────────────
var S2_START           = '2020-01-01';
var S2_END             = '2023-12-31';
var S2_CLOUD_THRESHOLD = 20;
// Growing season filter for temperate/boreal Canada (May–Sep).
// For tropical sites, comment out the calendarRange filter below.
var S2_MONTH_START = 5;
var S2_MONTH_END   = 9;

// ── Sentinel-1 SAR date range ────────────────────────────────────
var SAR_START = '2020-01-01';
var SAR_END   = '2023-12-31';

// ── TerraClimate date range ──────────────────────────────────────
var TC_START = '2000-01-01';
var TC_END   = '2022-12-31';

// ── Google Satellite Embedding ───────────────────────────────────
var EMBEDDING_YEAR = null;  // null = median composite (recommended)

// ── Sampling ─────────────────────────────────────────────────────
var N_SOIL_SAMPLES = 100;

// ── AOI display buffer ───────────────────────────────────────────
var AOI_BUFFER_M = 5000;


// ─────────────────────────────────────────────────────────────────
// SECTION B — GLOBAL STATE VARIABLES
// ─────────────────────────────────────────────────────────────────
var aoi          = null;
var aoi_display  = null;
var sg_soc_prior = null;
var cov_stack    = null;
var embed_img    = null;
var soil_pts     = null;
var snapshot_btn = null;


// ─────────────────────────────────────────────────────────────────
// SECTION C — HELPER FUNCTIONS
// ─────────────────────────────────────────────────────────────────

function maskS2clouds(image) {
  var qa = image.select('QA60');
  var cloudBitMask  = 1 << 10;
  var cirrusBitMask = 1 << 11;
  var mask = qa.bitwiseAnd(cloudBitMask).eq(0)
               .and(qa.bitwiseAnd(cirrusBitMask).eq(0));
  return image.updateMask(mask).divide(10000)
    .copyProperties(image, ['system:time_start']);
}

// Rename S2 bands and compute terrestrial spectral indices
function addS2IndicesAndRename(image) {
  var img = image.select(
    ['B2',  'B3', 'B4',  'B5', 'B6', 'B7',  'B8',  'B11',   'B12'],
    ['B',   'G',  'R',   'B5', 'B6', 'B7',  'NIR', 'SWIR1', 'SWIR2']
  );

  // NDVI: vegetation density — primary SOC proxy
  var ndvi = img.normalizedDifference(['NIR', 'R']).rename('NDVI_median');

  // EVI: atmosphere-corrected vegetation index
  var evi = img.expression(
    '2.5 * ((NIR - R) / (NIR + 6*R - 7.5*B + 1))',
    {NIR: img.select('NIR'), R: img.select('R'), B: img.select('B')}
  ).rename('EVI_median');

  // LSWI: land surface water index (soil/canopy moisture)
  var lswi = img.normalizedDifference(['NIR', 'SWIR1']).rename('LSWI_median');

  // SAVI: soil-adjusted vegetation index
  var savi = img.expression(
    '1.5 * (NIR - R) / (NIR + R + 0.5)',
    {NIR: img.select('NIR'), R: img.select('R')}
  ).rename('SAVI_median');

  // NDMI: normalised difference moisture index (plant water stress)
  var ndmi = img.normalizedDifference(['NIR', 'SWIR1']).rename('NDMI_median');

  // BSI: bare soil index — detects exposed mineral soils
  var bsi = img.expression(
    '((SWIR1 + R) - (NIR + B)) / ((SWIR1 + R) + (NIR + B))',
    {SWIR1: img.select('SWIR1'), R: img.select('R'),
     NIR:   img.select('NIR'),   B: img.select('B')}
  ).rename('BSI_median');

  return img.addBands([ndvi, evi, lswi, savi, ndmi, bsi]);
}

// TWI: Topographic Wetness Index
function computeTWI(dem) {
  var slope_rad = ee.Terrain.slope(dem).multiply(Math.PI / 180);
  var tan_slope = slope_rad.tan().max(0.001);
  var contrib = dem.gte(-9999).unmask(0).reduceNeighborhood({
    reducer: ee.Reducer.sum(),
    kernel: ee.Kernel.circle({radius: 20, units: 'pixels'})
  }).max(1);
  return contrib.divide(tan_slope).log().rename('twi');
}

// TPI: Topographic Position Index
function computeTPI(dem) {
  var focal_mean = dem.focalMean({radius: 300, units: 'meters'});
  return dem.subtract(focal_mean).rename('tpi');
}

// Curvature: std dev of slope within 3-pixel neighbourhood
// Convex = faster drainage; concave = water/SOC accumulation
function computeCurvature(dem) {
  var slope_img = ee.Terrain.slope(dem);
  return slope_img.reduceNeighborhood({
    reducer: ee.Reducer.stdDev(),
    kernel: ee.Kernel.circle({radius: 3, units: 'pixels'})
  }).rename('curvature');
}


// ─────────────────────────────────────────────────────────────────
// SECTION D — UI LAYOUT
// ─────────────────────────────────────────────────────────────────

var STATUS_LABEL = ui.Label({
  value: 'Ready. Run steps ①–⑥ in order.',
  style: {color: 'gray', fontSize: '12px', whiteSpace: 'pre'}
});

function setStatus(msg) { STATUS_LABEL.setValue(msg); }

var panel = ui.Panel({style: {width: '380px', padding: '10px'}});

panel.add(ui.Label({
  value: 'Terrestrial Soil Carbon — Covariate Extraction',
  style: {fontWeight: 'bold', fontSize: '15px', margin: '0 0 4px 0'}
}));
panel.add(ui.Label({
  value: '28-band terrestrial stack  |  IPCC-aligned depths',
  style: {color: '#5d4037', fontSize: '12px', margin: '0 0 8px 0'}
}));
panel.add(ui.Label('─────────────────────────────────', {color: '#ccc'}));

panel.add(ui.Label('Configuration', {fontWeight: 'bold', fontSize: '12px'}));
panel.add(ui.Label('  CRS:   EPSG:3347 (Canada Albers Equal Area)', {fontSize: '11px', color: '#555'}));
panel.add(ui.Label('  Scale: ' + EXPORT_SCALE + ' m (covariate) / ' + EMBED_SCALE + ' m (embedding)', {fontSize: '11px', color: '#555'}));
panel.add(ui.Label('  S2:    ' + S2_START + ' → ' + S2_END + ' (May–Sep)', {fontSize: '11px', color: '#555'}));
panel.add(ui.Label('  SAR:   ' + SAR_START + ' → ' + SAR_END, {fontSize: '11px', color: '#555'}));
panel.add(ui.Label('  TC:    ' + TC_START + ' → ' + TC_END, {fontSize: '11px', color: '#555'}));
panel.add(ui.Label('  N sampling points: ' + N_SOIL_SAMPLES, {fontSize: '11px', color: '#555'}));
panel.add(ui.Label('─────────────────────────────────', {color: '#ccc'}));

var btn1 = ui.Button('① Import AOI');
var btn2 = ui.Button('② Import Raster Priors (SoilGrids SOC + Clay)');
var btn3 = ui.Button('③ Build Terrestrial Covariate Stack (28 bands)');
var btn5 = ui.Button('⑤ Generate Stratified Sampling Points');
var btn6 = ui.Button('⑥ Reports and Exports');

panel.add(btn1); panel.add(btn2); panel.add(btn3);
panel.add(btn5); panel.add(btn6);
panel.add(ui.Label('─────────────────────────────────', {color: '#ccc'}));
panel.add(ui.Label('Status:', {fontWeight: 'bold', fontSize: '12px'}));
panel.add(STATUS_LABEL);

ui.root.add(panel);


// ─────────────────────────────────────────────────────────────────
// STEP 1 — IMPORT AOI
// ─────────────────────────────────────────────────────────────────
btn1.onClick(function step1_importAOI() {
  setStatus('Step ①: Loading AOI…');

  if (AOI_ASSET !== null) {
    var aoiFC = ee.FeatureCollection(AOI_ASSET);
    aoi = aoiFC.union().geometry();
    aoi_display = aoi.buffer(AOI_BUFFER_M);
    Map.centerObject(aoi, 11);
    Map.addLayer(aoiFC, {color: '5d4037', fillColor: '00000000', width: 2}, 'AOI Boundary');
    setStatus('Step ① ✓ — AOI loaded from asset.\n→ Run Step ②.');
  } else {
    Map.drawingTools().setShown(true);
    Map.drawingTools().setShape('polygon');
    Map.drawingTools().layers().reset();
    setStatus('Step ① — Draw your AOI on the map.\n' +
              'Click vertices, close polygon, then\nclick ① again to confirm.');

    var layers = Map.drawingTools().layers();
    if (layers.length() > 0) {
      aoi = layers.get(0).toGeometry();
      aoi_display = aoi.buffer(AOI_BUFFER_M);
      Map.centerObject(aoi, 11);
      setStatus('Step ① ✓ — AOI set from drawn polygon.\n→ Run Step ②.');
    }
  }

  var canada = ee.FeatureCollection('USDOS/LSIB_SIMPLE/2017')
    .filter(ee.Filter.eq('country_na', 'Canada'));
  Map.addLayer(canada, {color: 'aaaaaa', fillColor: '00000000', width: 1},
               'Canada Boundary', false);
});


// ─────────────────────────────────────────────────────────────────
// STEP 2 — IMPORT RASTER PRIORS (SoilGrids SOC + Clay)
// ─────────────────────────────────────────────────────────────────
btn2.onClick(function step2_importPriors() {
  if (!aoi) { setStatus('⚠ Run Step ① first.'); return; }
  setStatus('Step ②: Loading SoilGrids SOC + Clay priors…');

  var sg = ee.Image('projects/soilgrids-isric/soc_mean');

  // SOC stocks (kg/m²) aggregated to 3 canonical depth intervals
  var ocs_0_5    = sg.select('ocs_0-5cm_mean').divide(10).multiply(0.05);
  var ocs_5_15   = sg.select('ocs_5-15cm_mean').divide(10).multiply(0.10);
  var ocs_15_30  = sg.select('ocs_15-30cm_mean').divide(10).multiply(0.15);
  var ocs_30_60  = sg.select('ocs_30-60cm_mean').divide(10).multiply(0.30);
  var ocs_60_100 = sg.select('ocs_60-100cm_mean').divide(10).multiply(0.40);

  var sg_0_30   = ocs_0_5.add(ocs_5_15).add(ocs_15_30).rename('sg_soc_0_30cm');
  var sg_30_100 = ocs_30_60.add(ocs_60_100).rename('sg_soc_30_100cm');
  var sg_0_100  = sg_0_30.add(sg_30_100).rename('sg_soc_0_100cm');

  sg_soc_prior = sg_0_30.addBands(sg_30_100).addBands(sg_0_100);

  // SoilGrids Clay content 0–30 cm (clay stabilises SOC via organo-mineral associations)
  var sg_clay = ee.Image('projects/soilgrids-isric/clay_mean');
  var clay_0_5   = sg_clay.select('clay_0-5cm_mean');
  var clay_5_15  = sg_clay.select('clay_5-15cm_mean');
  var clay_15_30 = sg_clay.select('clay_15-30cm_mean');
  var clay_0_30  = clay_0_5.add(clay_5_15).add(clay_15_30).divide(3).rename('sg_clay_0_30cm');

  // Display
  var socVis  = {min: 0, max: 20, palette: ['f7fbff','c6dbef','6baed6','2171b5','08306b']};
  var clayVis = {min: 0, max: 60, palette: ['ffffd4','fed98e','fe9929','cc4c02']};

  Map.addLayer(sg_0_100.clip(aoi_display || aoi), socVis, 'SoilGrids SOC 0–100 cm (kg/m²)');
  Map.addLayer(clay_0_30.clip(aoi_display || aoi), clayVis, 'SoilGrids Clay 0–30 cm (%)', false);

  var stats = sg_0_100.reduceRegion({
    reducer: ee.Reducer.mean().combine(ee.Reducer.stdDev(), '', true),
    geometry: aoi, scale: 250, maxPixels: 1e9, bestEffort: true
  });
  stats.evaluate(function(s) {
    var mean = s.sg_soc_0_100cm_mean;
    var sd   = s.sg_soc_0_100cm_stdDev;
    print('SoilGrids SOC 0–100 cm (kg/m²) — AOI statistics:');
    print('  Mean: ' + (mean !== null ? mean.toFixed(2) : 'N/A'));
    print('  SD:   ' + (sd   !== null ? sd.toFixed(2)   : 'N/A'));
    setStatus('Step ② ✓ — SoilGrids SOC + Clay priors loaded.\n→ Run Step ③.');
  });
});


// ─────────────────────────────────────────────────────────────────
// STEP 3 — BUILD TERRESTRIAL COVARIATE STACK (28 canonical bands)
// ─────────────────────────────────────────────────────────────────
btn3.onClick(function step3_buildCovariates() {
  if (!sg_soc_prior) { setStatus('⚠ Run Steps ①–② first.'); return; }
  setStatus('Step ③: Building 28-band terrestrial covariate stack…');

  // ─────────────────────────────────────────────────
  // GROUP 1 — Topography & Terrain (6)
  // ─────────────────────────────────────────────────
  var dem   = ee.Image('NASA/NASADEM_HGT/001').select('elevation').rename('elevation_m');
  var slope = ee.Terrain.slope(dem).rename('slope');
  var aspect = ee.Terrain.aspect(dem).rename('aspect');
  var twi   = computeTWI(dem);
  var tpi   = computeTPI(dem);
  var curv  = computeCurvature(dem);

  var topo_stack = dem.addBands(slope).addBands(aspect)
                      .addBands(twi).addBands(tpi).addBands(curv);

  // ─────────────────────────────────────────────────
  // GROUP 2 — Sentinel-1 SAR (3)
  // ─────────────────────────────────────────────────
  var s1 = ee.ImageCollection('COPERNICUS/S1_GRD')
    .filter(ee.Filter.date(SAR_START, SAR_END))
    .filter(ee.Filter.eq('instrumentMode', 'IW'))
    .filter(ee.Filter.listContains('transmitterReceiverPolarisation', 'VV'))
    .filter(ee.Filter.listContains('transmitterReceiverPolarisation', 'VH'))
    .filter(ee.Filter.gt('VV', -30));

  var vv   = s1.select('VV').median().rename('VV_mean');
  var vh   = s1.select('VH').median().rename('VH_mean');
  var vvvh = vv.subtract(vh).rename('VVVH_ratio');
  var sar_stack = vv.addBands(vh).addBands(vvvh);

  // ─────────────────────────────────────────────────────
  // GROUP 3 + 4 — Sentinel-2 Optical + Indices (9 + 6)
  // ─────────────────────────────────────────────────────
  // Growing season composite (May–Sep) for peak canopy signal.
  // Adjust S2_MONTH_START / S2_MONTH_END in Section A for other climates.
  var s2 = ee.ImageCollection('COPERNICUS/S2_SR_HARMONIZED')
    .filter(ee.Filter.date(S2_START, S2_END))
    .filter(ee.Filter.lt('CLOUDY_PIXEL_PERCENTAGE', S2_CLOUD_THRESHOLD))
    .filter(ee.Filter.calendarRange(S2_MONTH_START, S2_MONTH_END, 'month'))
    .map(maskS2clouds)
    .map(addS2IndicesAndRename)
    .median();

  var s2_raw = s2.select(['B', 'G', 'R', 'B5', 'B6', 'B7', 'NIR', 'SWIR1', 'SWIR2']);
  var s2_idx = s2.select([
    'NDVI_median', 'EVI_median', 'LSWI_median',
    'SAVI_median', 'NDMI_median', 'BSI_median'
  ]);
  var s2_stack = s2_raw.addBands(s2_idx);

  // ─────────────────────────────────────────────────
  // GROUP 5 — Climate (4)
  // ─────────────────────────────────────────────────
  var tc     = ee.ImageCollection('IDAHO_EPSCOR/TERRACLIMATE').filter(ee.Filter.date(TC_START, TC_END));
  var mat    = tc.select('tmmx').mean().subtract(273.15).rename('MAT_C');
  var map_mm = tc.select('pr').mean().multiply(12).rename('MAP_mm');
  // PET: raw units are mm/month × 0.1 → ×12×0.1 = ×1.2
  var pet    = tc.select('pet').mean().multiply(1.2).rename('PET_mm');
  // Aridity index = MAP / PET (< 0.5 = arid, > 0.65 = humid)
  var ai     = map_mm.divide(pet.max(1)).rename('aridity_index');
  var climate_stack = mat.addBands(map_mm).addBands(pet).addBands(ai);

  // ─────────────────────────────────────────────────────────────────
  // ASSEMBLE canonical 28-band stack
  // ─────────────────────────────────────────────────────────────────
  cov_stack = topo_stack
    .addBands(sar_stack)
    .addBands(s2_stack)
    .addBands(climate_stack);

  // Google Satellite Embedding V1 (64 bands — separate export)
  var embed_col = ee.ImageCollection('GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL');
  if (EMBEDDING_YEAR !== null) {
    embed_col = embed_col.filter(ee.Filter.calendarRange(EMBEDDING_YEAR, EMBEDDING_YEAR, 'year'));
  }
  embed_img = embed_col.median();

  // ── Band inventory ──────────────────────────────────────────────
  print('═══════════════════════════════════════════════════════');
  print('Canonical 28-band terrestrial covariate stack:');
  print('  Group 1 — Topography (6):');
  print('    elevation_m, slope, aspect, twi, tpi, curvature');
  print('  Group 2 — SAR (3):');
  print('    VV_mean, VH_mean, VVVH_ratio');
  print('  Group 3 — S2 raw (9):');
  print('    B, G, R, B5, B6, B7, NIR, SWIR1, SWIR2');
  print('  Group 4 — S2 indices (6):');
  print('    NDVI_median, EVI_median, LSWI_median, SAVI_median, NDMI_median, BSI_median');
  print('  Group 5 — Climate (4):');
  print('    MAT_C, MAP_mm, PET_mm, aridity_index');
  print('  Optional priors (Step 2, separate export):');
  print('    sg_soc_0_30cm, sg_soc_30_100cm, sg_soc_0_100cm, sg_clay_0_30cm');
  print('  Embedding (separate 10 m export):');
  print('    64 bands — GOOGLE/SATELLITE_EMBEDDING/V1/ANNUAL');
  print('═══════════════════════════════════════════════════════');

  // ── Map layers ─────────────────────────────────────────────────
  var displayRegion = aoi_display || aoi;
  Map.addLayer(cov_stack.select('NDVI_median').clip(displayRegion),
    {min: -0.2, max: 0.9, palette: ['d73027','fee090','91cf60','1a9641']}, 'NDVI');
  Map.addLayer(cov_stack.select('EVI_median').clip(displayRegion),
    {min: -0.1, max: 0.7, palette: ['d73027','fee090','91cf60','1a9641']}, 'EVI', false);
  Map.addLayer(cov_stack.select('BSI_median').clip(displayRegion),
    {min: -0.4, max: 0.3, palette: ['1a9641','fee090','d73027']}, 'BSI (bare soil)', false);
  Map.addLayer(cov_stack.select('NDMI_median').clip(displayRegion),
    {min: -0.5, max: 0.5, palette: ['d73027','ffffbf','4575b4']}, 'NDMI', false);
  Map.addLayer(cov_stack.select('VV_mean').clip(displayRegion),
    {min: -25, max: -5, palette: ['000000','cccccc','ffffff']}, 'SAR VV', false);
  Map.addLayer(cov_stack.select('elevation_m').clip(displayRegion),
    {min: 0, max: 2000, palette: ['0571b0','92c5de','f7f7f7','d6604d','ca0020']}, 'Elevation (m)', false);
  Map.addLayer(cov_stack.select('twi').clip(displayRegion),
    {min: 0, max: 12, palette: ['f7fbff','c6dbef','6baed6','2171b5','08306b']}, 'TWI', false);
  Map.addLayer(cov_stack.select('tpi').clip(displayRegion),
    {min: -50, max: 50, palette: ['d73027','ffffbf','1a9641']}, 'TPI', false);
  Map.addLayer(cov_stack.select('MAT_C').clip(displayRegion),
    {min: -10, max: 20, palette: ['4575b4','ffffbf','d73027']}, 'MAT (°C)', false);
  Map.addLayer(cov_stack.select('aridity_index').clip(displayRegion),
    {min: 0, max: 2, palette: ['d73027','fee090','74add1','4575b4']}, 'Aridity index', false);
  Map.addLayer(sg_soc_prior.select('sg_soc_0_100cm').clip(displayRegion),
    {min: 0, max: 20, palette: ['f7fbff','6baed6','08306b']}, 'SoilGrids SOC 0–100 cm', false);

  // Insert ④ Export button
  if (!snapshot_btn) {
    snapshot_btn = ui.Button('④ Export Covariate Snapshot to Drive');
    snapshot_btn.onClick(step4_exportSnapshot);
    var children = panel.widgets();
    var btn5_idx = -1;
    for (var i = 0; i < children.length(); i++) {
      if (children.get(i) === btn5) { btn5_idx = i; break; }
    }
    if (btn5_idx >= 0) { panel.insert(btn5_idx, snapshot_btn); }
    else               { panel.add(snapshot_btn); }
  }

  setStatus('Step ③ ✓ — 28-band stack built.\n→ Run Step ④ to export to Drive.');
});


// ─────────────────────────────────────────────────────────────────
// STEP 4 — EXPORT COVARIATE SNAPSHOT
// ─────────────────────────────────────────────────────────────────
function step4_exportSnapshot() {
  if (!cov_stack) { setStatus('⚠ Run Step ③ first.'); return; }
  setStatus('Step ④: Queuing export tasks to Drive…');

  var exportRegion = aoi_display || aoi;

  // Task 1 — 28-band terrestrial covariate stack
  Export.image.toDrive({
    image          : cov_stack.clip(aoi),
    description    : 'TerrestrialSOC_Covariate_Snapshot_25m_' + PROJECT_YEAR,
    folder         : EXPORT_FOLDER,
    fileNamePrefix : 'TerrestrialSOC_Covariate_Snapshot_25m_' + PROJECT_YEAR,
    region         : exportRegion,
    scale          : EXPORT_SCALE,
    crs            : EXPORT_CRS,
    maxPixels      : 1e13,
    fileFormat     : 'GeoTIFF'
  });

  // Task 2 — Google Satellite Embedding V1 (64 bands, 10 m)
  Export.image.toDrive({
    image          : embed_img.clip(aoi),
    description    : 'TerrestrialSOC_GoogleEmbedding_V1_10m_' + PROJECT_YEAR,
    folder         : EXPORT_FOLDER,
    fileNamePrefix : 'TerrestrialSOC_GoogleEmbedding_V1_10m_' + PROJECT_YEAR,
    region         : exportRegion,
    scale          : EMBED_SCALE,
    crs            : EXPORT_CRS,
    maxPixels      : 1e13,
    fileFormat     : 'GeoTIFF'
  });

  // Task 3 — Optional SoilGrids priors (useful as model covariates)
  if (sg_soc_prior) {
    Export.image.toDrive({
      image          : sg_soc_prior.clip(aoi),
      description    : 'TerrestrialSOC_SoilGrids_Priors_250m_' + PROJECT_YEAR,
      folder         : EXPORT_FOLDER,
      fileNamePrefix : 'TerrestrialSOC_SoilGrids_Priors_250m_' + PROJECT_YEAR,
      region         : exportRegion,
      scale          : 250,
      crs            : EXPORT_CRS,
      maxPixels      : 1e13,
      fileFormat     : 'GeoTIFF'
    });
  }

  print('Export tasks queued (check Tasks panel → click Run):');
  print('  1. TerrestrialSOC_Covariate_Snapshot_25m_' + PROJECT_YEAR);
  print('     28 bands | ' + EXPORT_SCALE + ' m | ' + EXPORT_CRS);
  print('  2. TerrestrialSOC_GoogleEmbedding_V1_10m_' + PROJECT_YEAR);
  print('     64 bands | ' + EMBED_SCALE + ' m | ' + EXPORT_CRS);
  print('  3. TerrestrialSOC_SoilGrids_Priors_250m_' + PROJECT_YEAR);
  print('     4 bands (SOC 0-30, 30-100, 0-100, Clay 0-30) | 250 m');
  print('  Once downloaded, copy GeoTIFF to:');
  print('  Pre-Analysis Data Preparation/covariates/');

  setStatus('Step ④ ✓ — 3 export tasks queued.\nCheck Tasks panel.\n→ Run Step ⑤ for sampling points.');
}


// ─────────────────────────────────────────────────────────────────
// STEP 5 — GENERATE STRATIFIED SAMPLING POINTS
// ─────────────────────────────────────────────────────────────────
btn5.onClick(function step5_generateSampling() {
  if (!cov_stack) { setStatus('⚠ Run Steps ①–③ first.'); return; }
  setStatus('Step ⑤: Generating ' + N_SOIL_SAMPLES + ' sampling points…');

  var sg_0_100 = sg_soc_prior.select('sg_soc_0_100cm');
  var ndvi     = cov_stack.select('NDVI_median');
  var bsi      = cov_stack.select('BSI_median');

  // SOC uncertainty strata — percentile-based over the full AOI
  var soc_pct = sg_0_100.reduceRegion({
    reducer: ee.Reducer.percentile([33, 67]),
    geometry: aoi, scale: 250, maxPixels: 1e9, bestEffort: true
  });

  soc_pct.evaluate(function(pct) {
    var p33 = pct['sg_soc_0_100cm_p33'] || 3;
    var p67 = pct['sg_soc_0_100cm_p67'] || 10;

    // 3 strata across the full AOI (all land surface, not just tidal zone)
    var strata_img = ee.Image(0)
      .where(sg_0_100.lt(p33),              1)   // low SOC
      .where(sg_0_100.gte(p33).and(sg_0_100.lt(p67)), 2)   // medium SOC
      .where(sg_0_100.gte(p67),             3)   // high SOC
      .rename('stratum');

    var n_per_stratum = Math.ceil(N_SOIL_SAMPLES / 3);

    soil_pts = strata_img.stratifiedSample({
      numPoints: n_per_stratum,
      classBand: 'stratum',
      region: aoi,
      scale: EXPORT_SCALE,
      seed: 42,
      geometries: true
    });

    var labels = ee.Dictionary({
      '1': 'LowSOC',
      '2': 'MedSOC',
      '3': 'HighSOC'
    });
    soil_pts = soil_pts.map(function(f) {
      return f.set('stratum_label',
        labels.get(ee.String(f.get('stratum').toInt())));
    });

    Map.addLayer(soil_pts, {color: 'ff0000'}, 'Sampling Points (' + N_SOIL_SAMPLES + ')');

    print('Stratified sampling points generated:');
    print('  Stratum 1: LowSOC  (SOC < p33 = ' + p33.toFixed(1) + ' kg/m²)');
    print('  Stratum 2: MedSOC  (p33 – p67)');
    print('  Stratum 3: HighSOC (SOC > p67 = ' + p67.toFixed(1) + ' kg/m²)');

    setStatus('Step ⑤ ✓ — Sampling points generated.\n→ Run Step ⑥ to export reports.');
  });
});


// ─────────────────────────────────────────────────────────────────
// STEP 6 — REPORTS AND EXPORTS
// ─────────────────────────────────────────────────────────────────
btn6.onClick(function step6_reportsAndExports() {
  if (!cov_stack) { setStatus('⚠ Run Steps ①–③ first.'); return; }
  setStatus('Step ⑥: Computing statistics and queuing exports…');

  var stats = cov_stack.reduceRegion({
    reducer: ee.Reducer.mean()
      .combine(ee.Reducer.stdDev(), '', true)
      .combine(ee.Reducer.minMax(), '', true),
    geometry: aoi,
    scale: EXPORT_SCALE * 4,
    maxPixels: 1e9,
    bestEffort: true
  });

  stats.evaluate(function(s) {
    var bands = [
      'elevation_m', 'slope', 'aspect', 'twi', 'tpi', 'curvature',
      'VV_mean', 'VH_mean', 'VVVH_ratio',
      'NDVI_median', 'EVI_median', 'LSWI_median', 'SAVI_median', 'NDMI_median', 'BSI_median',
      'MAT_C', 'MAP_mm', 'PET_mm', 'aridity_index'
    ];
    print('═══════════════════════════════════════════════════════');
    print('AOI Covariate Summary:');
    bands.forEach(function(b) {
      var mean = s[b + '_mean'];
      var sd   = s[b + '_stdDev'];
      if (mean !== undefined && mean !== null) {
        print('  ' + b + ': mean = ' + mean.toFixed(3) + '  sd = ' + sd.toFixed(3));
      }
    });
    print('═══════════════════════════════════════════════════════');
  });

  // Band manifest CSV
  var band_names = [
    'elevation_m', 'slope', 'aspect', 'twi', 'tpi', 'curvature',
    'VV_mean', 'VH_mean', 'VVVH_ratio',
    'B', 'G', 'R', 'B5', 'B6', 'B7', 'NIR', 'SWIR1', 'SWIR2',
    'NDVI_median', 'EVI_median', 'LSWI_median', 'SAVI_median', 'NDMI_median', 'BSI_median',
    'MAT_C', 'MAP_mm', 'PET_mm', 'aridity_index'
  ];
  var band_groups = [
    'Topography','Topography','Topography','Topography','Topography','Topography',
    'SAR','SAR','SAR',
    'S2_Raw','S2_Raw','S2_Raw','S2_Raw','S2_Raw','S2_Raw','S2_Raw','S2_Raw','S2_Raw',
    'S2_Index','S2_Index','S2_Index','S2_Index','S2_Index','S2_Index',
    'Climate','Climate','Climate','Climate'
  ];

  var manifest_fc = ee.FeatureCollection(
    band_names.map(function(b, i) {
      return ee.Feature(null, {
        canonical_order: i + 1,
        band_name: b,
        group: band_groups[i]
      });
    })
  );

  Export.table.toDrive({
    collection   : manifest_fc,
    description  : 'TerrestrialSOC_BandManifest_' + PROJECT_YEAR,
    folder       : EXPORT_FOLDER,
    fileNamePrefix: 'TerrestrialSOC_BandManifest_' + PROJECT_YEAR,
    fileFormat   : 'CSV'
  });

  if (soil_pts) {
    Export.table.toDrive({
      collection   : soil_pts,
      description  : 'TerrestrialSOC_Sampling_Points_CSV_' + PROJECT_YEAR,
      folder       : EXPORT_FOLDER,
      fileNamePrefix: 'TerrestrialSOC_Sampling_Points_' + PROJECT_YEAR,
      fileFormat   : 'CSV'
    });
    Export.table.toDrive({
      collection   : soil_pts,
      description  : 'TerrestrialSOC_Sampling_Points_KML_' + PROJECT_YEAR,
      folder       : EXPORT_FOLDER,
      fileNamePrefix: 'TerrestrialSOC_Sampling_Points_' + PROJECT_YEAR,
      fileFormat   : 'KML'
    });
  }

  print('Exports queued. Go to Tasks panel → click Run on each.');
  print('  TerrestrialSOC_Covariate_Snapshot_25m_' + PROJECT_YEAR + '.tif  (28 bands)');
  print('  TerrestrialSOC_GoogleEmbedding_V1_10m_' + PROJECT_YEAR + '.tif  (64 bands)');
  print('  TerrestrialSOC_SoilGrids_Priors_250m_' + PROJECT_YEAR + '.tif   (4 bands)');
  print('  TerrestrialSOC_Sampling_Points_' + PROJECT_YEAR + '.csv/.kml');
  print('  TerrestrialSOC_BandManifest_' + PROJECT_YEAR + '.csv');

  setStatus('Step ⑥ ✓ — All exports queued.\nDone! Files go to Drive: ' + EXPORT_FOLDER);
});


// ─────────────────────────────────────────────────────────────────
// INITIAL SETUP
// ─────────────────────────────────────────────────────────────────
Map.setCenter(-96, 57, 5);   // Default: central Canada
Map.setOptions('SATELLITE');

print('Terrestrial Soil Carbon — AOI Covariate Extraction v2.0');
print('28-band terrestrial stack | IPCC-aligned depth intervals');
print('─────────────────────────────────────────────────────────');
print('Set AOI_ASSET in Section A or draw the boundary interactively.');
print('Then run steps ①–⑥ using the side panel buttons.');
