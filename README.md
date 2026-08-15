# AMORE: Animal Movement Overlap with Renewable Energy

MoveApps

Github repository: *github.com/REPLACE-WITH-YOUR-ACCOUNT/AMORE (replace with the actual repository URL before submission)*

## Description

MoveApp that screens animal movement datasets hosted on Movebank for their
spatio-temporal overlap with U.S. wind and solar energy infrastructure, and
flags tracks that may be good candidates for follow-up analyses of that
infrastructure's impacts on animal movement.

## Documentation

For the movement data associated with each individual tracked in the input
dataset, this MoveApp:

1. Checks for spatial overlap (within a configurable buffer distance)
   with wind turbines in the **U.S. Wind Turbine Database (USWTDB)** and
   solar arrays in the **Ground-Mounted Solar Energy in the US (GM-SEUS)**
   dataset, and reports how much of the track's exposure that represents
   (e.g. percent of tested fixes/days within the buffer, number and
   duration of distinct "visits" to the buffer, distances).
2. Where spatial overlap is found, classifies the tracking period relative to
   the infrastructure's operational year as `pre-operational`,
   `post-operational`, `spanning`, or `mixed` (i.e., movement data spans
   multiple facilities with different operational years).
3. Reports data-quality metrics (number of locations, tracking duration,
   days monitored, median fix interval) for every track, without applying
   a fixed pass/fail threshold -- what counts as "enough" data for a
   follow-up impact analysis depends on the taxon and research question,
   so the App presents the metrics and leaves that judgment to the user.

The App does not modify the tracking data (see *Changes in output data*
below). It produces two artefacts (see *Artefacts* below) and passes the
input through unchanged to be acted upon by subsequent MoveApps in a
potential workflow.

### Application scope

#### Generality of App usability

This App was developed for any taxonomic group -- the overlap and data-
quality metrics it computes make no taxon-specific assumptions. The optional
height-relative-to-turbine analysis (see *Height analysis* below) is most
relevant for taxa that fly (e.g. birds, bats), since it's meant to help
assess collision risk with rotor-swept airspace; it is harmless but
uninformative for taxa that don't move vertically through that space.

**Geographic scope:** this App is only applicable for datasets collected in
the **United States**, as both energy infrastructure datasets (USWTDB and
GM-SEUS) are U.S.-specific. Tracks entirely outside the contiguous extent of
USWTDB/GM-SEUS coverage will show no overlap by default -- this is expected
and not an error (see *Most common errors* below).

#### Required data properties

The App works with any `move2::move2_loc` dataset with valid location
coordinates; there's no strict minimum fix rate or tracking duration
required to *run* the App. However:

- The App does not apply a fixed pass/fail data-quality threshold -- it
  reports metrics (location count, tracking duration, days monitored,
  median fix interval) for every track and leaves it to the App user to
  judge what counts as "enough" data for their taxon and research question
  (see *Data quality summary* under *Artefacts* below). Sparse or short
  tracks aren't excluded or flagged; their metrics will simply reflect
  that sparsity.
- The optional **height analysis** requires the input data to include one
  of Movebank's standard height fields (`height_above_ground_level`,
  `height_above_mean_sea_level`, or `height_above_ellipsoid`); without one
  of these, height columns are simply reported as `NA` (see *Height
  analysis* below).
- Locations with missing/empty coordinates are automatically excluded
  before analysis (see *Null or error handling* below).

### Input type

`move2::move2_loc` -- tracking data with location information.

### Output type

`move2::move2_loc` -- identical to the input; this App is a
screening/reporting step and does not alter locations, tracks, or
attributes (see *Changes in output data* below).

### Artefacts

Both artefacts below are written to the path returned by the MoveApps
SDK's `appArtifactPath()` function (per the
[App Output](https://docs.moveapps.org/#/copilot-r-sdk?id=app-output) docs)
rather than to a bare filename in the working directory -- that's what
makes them show up as downloadable outputs in the Workflow's Output
overview. Each is a single file, so no zipping is needed. See *Example
output* below for a preview of what these look like.

- `renewable_overlap_summary.csv`: one row per tracked individual, with columns
  for study name, individual ID, taxon, and:
  - **Data quality metrics** (no pass/fail flag -- see *Required data
    properties* above): `n_locations`, `duration_days`,
    `median_fix_interval_hours`, and `n_days_monitored` (distinct calendar
    days represented by the tested, possibly-thinned point set -- the PDF
    report additionally displays this as a percentage of `duration_days`,
    computed at display time rather than stored as its own CSV column).
  - **Overlap and exposure-intensity metrics**, separately for wind and
    solar (`wind_*`/`solar_*` or `*_wind`/`*_solar` prefixes/suffixes
    below): whether the track overlapped at all (`overlaps_wind`/
    `overlaps_solar`) and the combined count of distinct facilities with
    either point-confirmed or interpolated-path evidence
    (`n_turbines_overlap`/`n_solar_arrays_overlap`). For point-confirmed
    detections specifically: the percent of tested fixes and distinct days
    spent within the buffer (`pct_wind_points_in_buffer`/
    `pct_wind_days_in_buffer` and solar equivalents), the number of
    separate "visit bouts" and the longest one's duration in hours
    (`n_wind_visit_bouts`/`wind_longest_buffer_bout_hours` and solar
    equivalents -- see the bout definition below), and both the nearest
    and median distance to infrastructure across all tested fixes
    (`nearest_turbine_dist_m`/`wind_dist_median_m` and solar equivalents).
  - **Temporal relation** (`wind_temporal_relation`/
    `solar_temporal_relation`): the track's timing relative to the
    infrastructure's operational year -- see *Documentation* above for the
    category definitions.
  - A few additional columns exist in the CSV but aren't surfaced in the
    PDF report: the raw (non-percentage) point-confirmed counts
    (`n_wind_points_in_buffer`/`n_solar_points_in_buffer` -- also the
    denominator behind the height section's rotor-zone percentage, see
    *Height analysis* below), the raw track-only-evidence counts
    (`n_turbines_track_only`/`n_solar_arrays_track_only` -- facilities the
    interpolated path passed within the buffer of but no single recorded
    fix confirmed), and `solar_instYr_confidence_diff` (the gap, in years,
    between GM-SEUS's `instYr` and its independent `instYrEst` field for
    the closest-diverging overlapping array -- a soft corroboration signal,
    not a validity flag).

  **Visit bout definition:** a bout is a maximal run of temporally-
  consecutive tested fixes that are each individually within the buffer.
  It ends the moment a fix in the sequence is recorded *outside* the
  buffer -- direct evidence the animal left -- so distinct bouts reflect
  repeat visits, while one long stay (even if sampled at a coarse fix
  interval) stays a single bout. This is deliberately based on recorded
  evidence rather than an assumed time threshold: if there's a large gap
  in the data with no fixes recorded at all (in or out of the buffer)
  between two in-buffer fixes, that's read as one continuous bout rather
  than being split, since there's no direct evidence the animal actually
  left during an unobserved gap.

  Designed so that outputs from many App runs can be concatenated into a
  single corpus-wide table for cross-study comparison. If
  `include_height_analysis` is on, additional wind-specific height columns
  are included -- see *Height analysis* below.
- `renewable_overlap_report.pdf`: narrative summary of the study
  (data-quality and exposure-intensity tables, key-highlights callouts,
  and a map of nearby infrastructure, per individual).

### Settings

*Setting names below match what the App user sees in the Settings menu
(as defined in `appspec.json`); the argument name in parentheses is what's
used in `RFunction.R`.*

- `Overlap buffer distance (m)` (buffer_distance_m): How close a track must
  come to a turbine/array to count as "overlapping." Unit: `metres`.
  Default: `1000`.
- `Check wind turbine overlap` (include_wind): Whether to check the
  tracking data against the USWTDB. Default: `TRUE` (on).
- `Check solar array overlap` (include_solar): Whether to check the
  tracking data against the GM-SEUS dataset. Default: `TRUE` (on).
- `Infrastructure query region` (query_region_mode): How to define the
  search region used to fetch candidate infrastructure -- `"bbox"` uses one
  buffered bounding box for the whole dataset; `"trajectory"` queries with
  one buffered bounding box per track instead, merging results. See *Scale
  and performance* below for why this matters for wide-ranging or migratory
  data. Default: `"bbox"`.
- `Thin locations for overlap test on very large tracks` (enable_thinning):
  For extremely high-frequency/long-duration tracks, optionally subsample
  locations before the infrastructure overlap test (data-quality metrics
  always use the full, unthinned track regardless of this setting).
  Default: `FALSE` (off).
- `Max locations per track for overlap test (if thinning enabled)`
  (thinning_max_locations): When thinning is enabled, tracks with more
  locations than this are evenly subsampled down to approximately this many
  points before the overlap test. Default: `5000`.
- `Analyze location height relative to wind turbines`
  (include_height_analysis): Wind only. If the input data includes a
  recognized Movebank height field, reports the height of locations near
  turbines -- see *Height analysis* below. Default: `FALSE` (off).

This App does not expose data-quality pass/fail thresholds as settings --
it reports the quality metrics for every track (see *Data quality summary*
under *Artefacts* above) and leaves the judgment of what's "enough" data
to the App user, since that depends on the taxon and research question.

### Changes in output data

The input data is returned completely unchanged -- no columns are added,
removed, or modified, and no locations are filtered out of the returned
object (the internal exclusion of locations with missing/empty coordinates,
described under *Null or error handling*, only affects this App's own
overlap/quality calculations, not what's passed on).

All of this App's results -- overlap flags, distances, temporal
classifications, and quality metrics -- are written only to the two
artefacts described above (`renewable_overlap_summary.csv` and
`renewable_overlap_report.pdf`), not to the tracking data itself. This
makes the App a pure screening/reporting step that's safe to insert
anywhere in a Workflow without affecting what downstream Apps receive.

### Most common errors

- No infrastructure found: expected and not an error for tracks outside the
  U.S., or in U.S. regions without nearby wind/solar development.
- GM-SEUS load failures: this App reads a small bundled extract, shipped as
  a MoveApps fixed auxiliary file (`gmseus_arrays`, resolved at runtime via
  `resolve_app_file("gmseus_arrays")`) rather than the live/full
  dataset -- see *Auxiliary files* below. If that file is missing (e.g. not
  committed, or a fresh clone of the repo before running
  `data-raw/extract_gmseus_arrays.R`), solar checks fail gracefully
  (logged, solar columns left `NA`) rather than failing the whole run.

### Null or error handling

**Input data:**

- Locations with missing or empty coordinates are excluded from this App's
  own calculations before any spatial analysis runs (a single bad geometry
  can otherwise corrupt spatially-indexed distance queries for the whole
  dataset); this exclusion is internal only and does not affect the
  returned tracking data (see *Changes in output data*).
- Tracks with zero valid locations remaining after that exclusion are
  reported explicitly in the CSV with `n_locations = 0` and all overlap/
  quality columns `NA`, rather than causing an error.
- Tracks with fewer than 2 locations are still processed for point-based
  overlap, but will have `NA` median fix interval, since that metric
  requires at least two fixes to compute an interval between them.

**Settings:**

- **Setting `include_wind` / `include_solar`:** if neither is set, the App
  still runs and produces quality metrics with all overlap columns `NA`.
- **Setting `query_region_mode`:** an unrecognized value falls back to
  `"bbox"` with a logged warning, rather than erroring.
- **Setting `include_height_analysis`:** if on but no recognized height
  column is found on the input data, height columns are `NA` and this is
  logged, not silently ignored (see *Height analysis*).

**Other:**

- **PDF rendering failures:** caught and logged without failing the whole
  App run -- the CSV artefact is still produced even if the PDF report
  fails to render for some reason.

## Example output

*Add a screenshot here once you've run the App on real data*, so users can
see what they'll get before running it themselves. To add one:

1. Run the App (locally or via a MoveApps Workflow) on a real dataset.
2. Take a screenshot of one or both artefacts -- e.g. the first page of
   `renewable_overlap_report.pdf` (which includes the screening summary and
   overview map), and/or `renewable_overlap_summary.csv` opened in a
   spreadsheet program.
3. Save the image into the repo, e.g. as `docs/example_report_screenshot.png`
   (create the `docs/` folder if it doesn't exist).
4. Replace this section's placeholder text with an image embed pointing at
   that file:

   ```markdown
   ![Example report output](docs/example_report_screenshot.png)
   ```

5. If you use real study data for the screenshot, double check it's OK to
   share publicly (e.g. no sensitive tracking data for at-risk species)
   before committing it to the repo -- consider using a public/example
   dataset instead if in doubt.

## Height analysis

Off by default, and wind-only (ground-mounted solar arrays don't have an
equivalent vertical hazard zone). When enabled, the App looks for a
recognized Movebank height field on the input data, checked in this
priority order:

1. **`height_above_ground_level`** -- true height above ground. This is the
   only case where an actual rotor-swept-zone pass/fail classification is
   computed, using USWTDB's `t_hh` (hub height) and `t_rd` (rotor diameter):
   a point counts as in the rotor zone if its height falls within
   `hub_height +/- (rotor_diameter / 2)` of any turbine it's already within
   the horizontal buffer of.
2. **`height_above_mean_sea_level`** or **`height_above_ellipsoid`** --
   neither is height above ground, and the App does not apply a
   ground-elevation correction (that would require fetching a digital
   elevation model, a deliberate scope decision to avoid adding that
   dependency). These are reported as informational context only --
   min/median/max recorded height near turbines -- with no zone
   classification attempted.
3. **`height_raw`** is deliberately never used automatically -- per
   Movebank's own field definition its values can be non-numeric and
   study-specific (e.g. `"425, 2D fix"`), too unreliable to parse safely.

If none of the above are present, or the setting is off, all height columns
are `NA` and this is logged, not silently ignored.

New CSV columns (all wind-specific): `wind_height_field_used`,
`wind_height_is_agl`, `n_wind_points_in_rotor_zone` (only ever non-NA when
`wind_height_is_agl` is `TRUE`), `wind_height_min_m`, `wind_height_median_m`,
`wind_height_max_m`.

**Important scope note:** height is only evaluated for points already found
within the horizontal buffer of a turbine. This is a refinement of existing
horizontal overlap results, not an independent 3D search -- a track that
never registers as horizontally "near" a turbine (e.g. `buffer_distance_m`
set too tight) won't have its height checked against that turbine at all,
regardless of actual flight altitude.

## Scale and performance

Movement datasets can be large in three different ways, and this App
handles each differently:

- **Many locations per individual**: the infrastructure overlap test uses
  spatially-indexed predicates (`st_is_within_distance`, `st_nearest_feature`)
  rather than building a buffered union-of-points polygon or a dense
  pairwise distance matrix, so it scales to tracks with very large numbers
  of fixes without a proportional blowup in memory or compute. For
  extreme cases, `enable_thinning` optionally subsamples locations for the
  overlap test only -- quality metrics (location count, duration, fix
  interval) always reflect the full, untouched track.
- **Many individuals per study**: tracks are processed and summarized one
  at a time, so memory use doesn't scale with the number of concurrent
  individuals held in memory at once.
- **Wide-ranging / migratory extents**: a bounding box around a track that
  spans a huge area (e.g. a bird migrating between continents) can include
  enormous empty interior, pulling in far more candidate infrastructure
  than actually matters and inflating query size. `query_region_mode =
  "trajectory"` instead queries USWTDB with one buffered bounding box per
  track rather than one box for the whole study, avoiding the empty gap
  between disjoint areas (e.g. separate breeding and wintering grounds).
  This does mean one API call per track rather than one per study, so for
  studies with very many individuals it trades more requests for tighter
  queries -- a natural future enhancement would cluster nearby tracks into
  shared boxes rather than querying every track separately. This only
  affects which infrastructure is *fetched as a candidate* -- the overlap
  test itself always uses full-resolution points regardless of this
  setting. GM-SEUS needs no equivalent since it's loaded in full from the
  small bundled extract.

## Data sources & licensing

- **USWTDB**: Hoen, B.D. et al., USGS/LBNL/American Clean Power Association.
  CC BY 3.0. Queried live via the [USWTDB REST API](https://eerscmap.usgs.gov/uswtdb/api-doc/)
  at runtime (a PostgREST-style API with column-range filtering, not a
  spatial/GIS query service).
- **GM-SEUS**: Stid et al., Michigan State University. CC BY 4.0
  (attribution required; v2.0, [Zenodo record 19581821](https://zenodo.org/records/19581821)).
  The full release is distributed as one large (~3.7GB) zip; this App instead
  bundles a small, slimmed-down extract of just the array layer and fields
  it needs, permitted under the CC-BY 4.0 license with attribution. See
  `data-raw/extract_gmseus_arrays.R` for how to regenerate this extract
  from a fresh GM-SEUS release, and *Auxiliary files* below for how it's
  shipped and loaded.

## Auxiliary files

This App ships two **fixed auxiliary files** (App-developer-provided
files, not something the App user uploads), each declared in
`appspec.json` under `providedAppFiles`. Rather than calling
`getAppFilePath()` directly, `RFunction.R` resolves both through a small
wrapper, `resolve_app_file()`: the SDK's documented examples aren't fully
consistent about whether `getAppFilePath()` returns a file path directly
or the containing folder, so the wrapper handles either case (if the
resolved path is a directory, it looks inside for the single non-hidden
file). This is safer than assuming one convention and keeps each file's
on-disk location an implementation detail of the MoveApps SDK either way:

- **`gmseus_arrays`** (`settingId: "gmseus_arrays"`): the bundled GM-SEUS
  array extract described above. Lives in the repo at
  `data/auxiliary/user-files/provided-app-files/gmseus_arrays/` (exactly
  one non-hidden file in that folder). Resolved in `RFunction.R`'s
  `fetch_gmseus()` via `resolve_app_file("gmseus_arrays")`. To update it
  (e.g. a new GM-SEUS release), regenerate with
  `data-raw/extract_gmseus_arrays.R` and replace the committed file in
  that same folder.
- **`report_template`** (`settingId: "report_template"`): the
  `report_template.Rmd` used to render `renewable_overlap_report.pdf`.
  Lives in the repo at
  `data/auxiliary/user-files/provided-app-files/report_template/` (again,
  exactly one non-hidden file -- `report_template.Rmd`). Resolved in
  `RFunction.R` just before the `rmarkdown::render()` call via
  `resolve_app_file("report_template")`.

Both are *fixed* auxiliary files only -- there's no corresponding
user-upload option for App users to override either one, since neither is
derived from or specific to the input tracking data.

---

*Template based on [movestore/Template_R_Function_App](https://github.com/movestore/Template_R_Function_App).*
*Code annotated and partially produced by Claude's Sonnet 5 LLM*
