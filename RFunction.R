library("move2")
library("sf")
library("dplyr")
library("purrr")
library("httr2")
library("rmarkdown")

# ---------------------------------------------------------------------------
# CONFIG: static source locations
# ---------------------------------------------------------------------------

# USWTDB REST API (PostgREST-style; NOT an ArcGIS/Esri service). Row
# filtering is by column comparison operators (eq/gt/lt/gte/lte/in/etc.) --
# there is no native spatial/polygon filter, only range filters on the
# xlong/ylat columns. See https://eerscmap.usgs.gov/uswtdb/api-doc/
USWTDB_QUERY_URL <- "https://energy.usgs.gov/api/uswtdb/v1/turbines"

# GM-SEUS array-level layer, shipped as a MoveApps fixed auxiliary file
# (settingId "gmseus_arrays" in appspec.json's providedAppFiles, resolved
# at runtime via getAppFilePath() -- see fetch_gmseus() below) rather
# than being read from a hardcoded repo-relative path. This is a small
# extract (permitted under GM-SEUS v2.0's CC-BY 4.0 license, with
# attribution -- see README), NOT the full ~3.7GB Zenodo release; it's a
# slimmed-down copy of just the array layer/fields this App needs,
# produced by data-raw/extract_gmseus_arrays.R. Regenerate it from a fresh
# GM-SEUS release using that script if you need to update the source data,
# then replace the file committed under
# data/auxiliary/user-files/provided-app-files/gmseus_arrays/ (see README's
# Auxiliary files section).
# Source: https://zenodo.org/records/19581821 (Stid et al., CC-BY 4.0)
GMSEUS_AUX_SETTING_ID <- "gmseus_arrays"

# ---------------------------------------------------------------------------
# MAIN ENTRY POINT
# ---------------------------------------------------------------------------

rFunction <- function(data,
                       sdk,
                       buffer_distance_m = 1000,
                       include_wind = TRUE,
                       include_solar = TRUE,
                       query_region_mode = "bbox",
                       enable_thinning = FALSE,
                       thinning_max_locations = 5000,
                       include_height_analysis = FALSE,
                       ...) {

  logger.info("Starting Renewable Energy Infrastructure Overlap App")
  logger.info(paste("Buffer distance:", buffer_distance_m, "m"))

  query_region_mode <- tolower(query_region_mode)
  if (!query_region_mode %in% c("bbox", "trajectory")) {
    logger.warn(paste0("Unrecognized query_region_mode '", query_region_mode,
                             "', defaulting to 'bbox'"))
    query_region_mode <- "bbox"
  }
  logger.info(paste("Query region mode:", query_region_mode))

  study_name <- tryCatch(
    unique(move2::mt_track_data(data)$study_name)[1],
    error = function(e) NA_character_
  )

  # Per-track taxon, pulled from Movebank's standard reference-data columns.
  # "individual_taxon_canonical_name" is the standard Movebank field for
  # this; a couple of variant names are checked as a fallback since this
  # hasn't been verified against every possible study's exact column
  # naming -- if none match, taxon comes back NA rather than erroring the
  # whole run.
  track_taxa <- tryCatch({
    track_data_tbl <- move2::mt_track_data(data)
    tid_col <- move2::mt_track_id_column(data)
    taxon_candidates <- c("taxon_canonical_name", "individual_taxon_canonical_name",
                           "taxon_ids", "individual_taxon", "taxon")
    taxon_col <- intersect(taxon_candidates, names(track_data_tbl))

    if (length(taxon_col) == 0) {
      logger.warn("No recognized taxon column found in track data; taxon will be NA")
      tibble::tibble(track_id = as.character(track_data_tbl[[tid_col]]), taxon = NA_character_)
    } else {
      tibble::tibble(track_id = as.character(track_data_tbl[[tid_col]]),
                      taxon = as.character(track_data_tbl[[taxon_col[1]]]))
    }
  }, error = function(e) {
    logger.warn(paste("Could not extract taxon metadata:", conditionMessage(e)))
    tibble::tibble(track_id = character(0), taxon = character(0))
  })

  # Height field detection (wind-only feature, gated by include_height_analysis).
  # Priority order follows Movebank's vocabulary definitions:
  #   1. height_above_ground_level -- true AGL, usable directly for a
  #      rotor-swept-zone classification.
  #   2/3. height_above_mean_sea_level / height_above_ellipsoid -- NOT AGL
  #      (no ground-elevation correction applied), reported as informational
  #      context only, never used for a pass/fail classification.
  #   height_raw is deliberately excluded -- its values can be non-numeric
  #   and study-specific ("425, 2D fix"), too unreliable to parse automatically.
  height_field <- NA_character_
  height_is_agl <- NA
  if (include_height_analysis) {
    height_candidates_agl <- "height_above_ground_level"
    height_candidates_other <- c("height_above_mean_sea_level", "height_above_ellipsoid")
    data_cols <- names(data)

    if (height_candidates_agl %in% data_cols) {
      height_field <- height_candidates_agl
      height_is_agl <- TRUE
    } else {
      found <- intersect(height_candidates_other, data_cols)
      if (length(found) > 0) {
        height_field <- found[1]
        height_is_agl <- FALSE
      }
    }

    if (is.na(height_field)) {
      logger.warn(paste(
        "include_height_analysis is on, but no recognized height column",
        "(height_above_ground_level, height_above_mean_sea_level, or",
        "height_above_ellipsoid) was found; height columns will be NA"
      ))
    } else {
      logger.info(paste0(
        "Using height field '", height_field, "' (",
        if (height_is_agl) "true AGL, rotor-zone classification enabled" else "not AGL, informational only",
        ")"
      ))
    }
  }

  track_ids <- unique(move2::mt_track_id(data))
  logger.info(paste("Processing", length(track_ids), "track(s)"))

  data_sf <- sf::st_as_sf(data)

  # Filter out locations with missing/empty coordinates before anything else
  # touches this data. Real Movebank exports commonly retain rows with
  # failed or missing GPS fixes rather than dropping them, and sf::st_as_sf()
  # silently turns those into empty point geometries. A single empty/
  # degenerate geometry passed into a spatial-index-based predicate (like
  # st_is_within_distance, used below) can corrupt results for the WHOLE
  # query, not just that one row -- this was previously causing every solar
  # array nationwide to spuriously register as "within distance" of tracks
  # that had even one bad fix. Doing this once, here, means no downstream
  # calculation (quality metrics, overlap tests) needs its own defensive
  # check.
  n_locations_raw <- nrow(data_sf)
  empty_idx <- sf::st_is_empty(data_sf)
  if (any(empty_idx)) {
    logger.warn(paste0(
      sum(empty_idx), " of ", n_locations_raw,
      " location(s) have missing/empty coordinates and were excluded"
    ))
    data_sf <- data_sf[!empty_idx, ]
  }

  # Fetch GM-SEUS (if requested) before choosing a working CRS -- see below.
  solar_polys <- if (include_solar) fetch_gmseus(sdk) else NULL

  # Choose a metric working CRS for all buffering/distance calculations.
  #
  # IMPORTANT: when solar is included, use GM-SEUS's own native CRS --
  # NAD83(2011) / Conus Albers, an equal-area projection specifically valid
  # across the whole contiguous US -- rather than a local UTM zone picked
  # from the track's centroid. GM-SEUS is a large, geographically dispersed
  # nationwide dataset; force-reprojecting all of it into a single local UTM
  # zone can produce severely distorted or outright invalid geometry for
  # anything far from that zone's central meridian (UTM/Transverse Mercator
  # only behaves well within a few degrees of its own meridian). This
  # previously caused every array nationwide to spuriously register as
  # "within distance" of tracks located far from the chosen zone, because
  # some reprojected geometries became degenerate. Track and turbine data
  # are comparatively small and localized, so it's the transform direction
  # that should flip: transform THEM into a nationwide-safe CRS, not the
  # other way around.
  # When solar is excluded, there's no nationwide dataset in play, so a
  # study-local UTM zone remains a fine (and more locally-accurate) choice
  # for wind-only distance calculations.
  working_crs <- if (!is.null(solar_polys)) {
    sf::st_crs(solar_polys)
  } else {
    suggest_utm_crs(data_sf)
  }

  data_proj <- sf::st_transform(data_sf, working_crs)
  # solar_polys is already in working_crs when non-NULL (that's how
  # working_crs was chosen) -- no transform needed, deliberately skipped.

  # -------------------------------------------------------------------------
  # Build the search region(s) used to query USWTDB. The API only supports
  # column-range filters (on xlong/ylat), not arbitrary polygon geometry, so
  # the region is a set of one or more bounding boxes:
  #  - "bbox" mode: a single buffered bounding box for the whole dataset --
  #    simple, but for wide-ranging/migratory tracks can include huge empty
  #    interior area (e.g. a box around an Alaska-to-Argentina migration
  #    covers nearly the whole Western Hemisphere).
  #  - "trajectory" mode: one buffered bounding box PER TRACK, queried and
  #    merged separately -- avoids pulling in irrelevant infrastructure from
  #    the empty gap between disjoint areas (e.g. separate breeding/wintering
  #    grounds), at the cost of one API call per track instead of one per
  #    study. For studies with many individuals this means many more calls;
  #    a future enhancement could cluster nearby tracks into shared boxes.
  # This only affects which turbines are *fetched as candidates* -- the
  # overlap test itself always uses full-resolution points regardless of
  # this mode (see summarize_infra_overlap).
  query_bboxes_wgs84 <- build_query_bboxes(
    data_proj, track_ids, mode = query_region_mode, buffer_distance_m = buffer_distance_m
  )

  wind_pts <- if (include_wind) fetch_uswtdb(query_bboxes_wgs84) else NULL
  if (!is.null(wind_pts)) {
    wind_pts <- sf::st_transform(wind_pts, working_crs)
    logger.info("Reprojected wind turbine data")
  }

  # -------------------------------------------------------------------------
  # Per-track overlap + quality summary
  # -------------------------------------------------------------------------
  n_tracks <- length(track_ids)
  track_results <- purrr::imap_dfr(track_ids, function(tid, i) {
    logger.info(paste0("Processing track ", i, " of ", n_tracks, " (", tid, ")"))
    track_pts <- data_proj[move2::mt_track_id(data_proj) == tid, ]
    summarize_track(
      track_pts        = track_pts,
      track_id         = tid,
      study_name       = study_name,
      wind_pts         = wind_pts,
      solar_polys      = solar_polys,
      buffer_distance_m = buffer_distance_m,
      enable_thinning   = enable_thinning,
      thinning_max_locations = thinning_max_locations,
      height_field      = height_field,
      height_is_agl     = height_is_agl
    )
  })

  # Merge in per-track taxon and place it right after track_id.
  track_results <- track_results %>%
    dplyr::left_join(track_taxa, by = "track_id") %>%
    dplyr::relocate(taxon, .after = track_id)

  # -------------------------------------------------------------------------
  # Build a lightweight set of track points (WGS84) for the report's map.
  # Thinned per track since full resolution isn't needed for a static PDF
  # figure -- for a track with tens of thousands of points it'd be slow to
  # render and visually indistinguishable from a much smaller sample anyway.
  # -------------------------------------------------------------------------
  track_points_map <- purrr::map_dfr(track_ids, function(tid) {
    pts <- data_proj[move2::mt_track_id(data_proj) == tid, ]
    if (nrow(pts) == 0) return(NULL)
    pts <- thin_points_for_overlap(pts, max_locations = 1000)
    sf::st_sf(track_id = as.character(tid), geometry = sf::st_geometry(pts))
  })
  if (nrow(track_points_map) > 0) {
    track_points_map <- sf::st_transform(track_points_map, 4326)
  }

  # -------------------------------------------------------------------------
  # Write standardized CSV artifact (one row per track; stacks across studies)
  #
  # Per MoveApps' App Output docs, artifacts must be written to the path
  # returned by appArtifactPath() rather than a bare filename in the
  # working directory -- that's what makes them show up as downloadable
  # outputs in the Workflow's Output overview.
  # -------------------------------------------------------------------------
  csv_artifact_path <- appArtifactPath("renewable_overlap_summary.csv")
  utils::write.csv(track_results, file = csv_artifact_path, row.names = FALSE)
  logger.info(paste("Wrote artifact:", csv_artifact_path))

  # -------------------------------------------------------------------------
  # Render narrative PDF artifact
  # -------------------------------------------------------------------------
  tryCatch({
    # report_template.Rmd is shipped as a MoveApps fixed auxiliary file
    # (settingId "report_template", declared in appspec.json's
    # providedAppFiles) rather than referenced by a hardcoded repo-relative
    # path -- resolved at runtime via getAppFilePath(), same
    # mechanism/rationale as the bundled GM-SEUS extract above.
    report_template_path <- resolve_app_file("report_template")
    if (is.na(report_template_path) || !file.exists(report_template_path)) {
      stop(paste0(
        "report_template auxiliary file not found",
        if (!is.na(report_template_path)) paste0(" at '", report_template_path, "'") else "",
        ". Confirm data/auxiliary/user-files/provided-app-files/report_template/ ",
        "contains exactly one file (report_template.Rmd), and that it's ",
        "declared under providedAppFiles in appspec.json."
      ))
    }

    # rmarkdown::render() takes output_file (a filename) and output_dir
    # separately rather than one combined path, so appArtifactPath()'s
    # result -- the correct full artifact path/filename per the MoveApps
    # App Output docs -- is split into those two pieces here.
    pdf_artifact_path <- appArtifactPath("renewable_overlap_report.pdf")

    rmarkdown::render(
      input       = report_template_path,
      output_file = basename(pdf_artifact_path),
      output_dir  = dirname(pdf_artifact_path),
      # Neither the auxiliary-file directory (the input's location) nor
      # necessarily the artifact directory is guaranteed writable for
      # scratch files, so intermediate knit files (which rmarkdown::render()
      # otherwise places next to the input by default) are pinned to the
      # App's own working directory instead.
      intermediates_dir = getwd(),
      params      = list(
        study_name    = study_name,
        track_results = track_results,
        track_points  = track_points_map,
        wind_pts      = wind_pts,
        solar_polys   = solar_polys,
        buffer_distance_m = buffer_distance_m
      ),
      envir = new.env(),
      quiet = TRUE
    )
    logger.info(paste("Wrote artifact:", pdf_artifact_path))
  }, error = function(e) {
    logger.error(paste("PDF rendering failed:", conditionMessage(e)))
  })

  # Pass tracking data through unchanged to the next App in the workflow
  return(data)
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

#' Suggest a UTM CRS (EPSG code) based on the centroid of an sf object
suggest_utm_crs <- function(x) {
  centroid <- sf::st_coordinates(sf::st_centroid(sf::st_union(sf::st_geometry(x))))
  lon <- centroid[1]; lat <- centroid[2]
  zone <- floor((lon + 180) / 6) + 1
  epsg <- if (lat >= 0) 32600 + zone else 32700 + zone
  sf::st_crs(epsg)
}

#' Build the USWTDB search region(s) as a list of bounding boxes (WGS84).
#' The API only supports column-range filters (xlong/ylat), so a bounding
#' box -- not an arbitrary polygon -- is the unit of query here.
#' mode = "bbox": one buffered bbox for the whole dataset.
#' mode = "trajectory": one buffered bbox per track, queried separately and
#'   merged/deduplicated by fetch_uswtdb() -- tighter for wide-ranging or
#'   migratory data with disjoint clusters, at the cost of more API calls.
build_query_bboxes <- function(data_proj, track_ids, mode, buffer_distance_m) {
  to_bbox_wgs84 <- function(geom) {
    buffered <- sf::st_buffer(sf::st_as_sfc(sf::st_bbox(geom)), buffer_distance_m)
    sf::st_bbox(sf::st_transform(buffered, 4326))
  }

  if (mode == "bbox") {
    return(list(to_bbox_wgs84(data_proj)))
  }

  purrr::map(track_ids, function(tid) {
    pts <- data_proj[move2::mt_track_id(data_proj) == tid, ]
    to_bbox_wgs84(pts)
  })
}

#' Query the USWTDB REST API (PostgREST-style; see
#' https://eerscmap.usgs.gov/uswtdb/api-doc/) for turbines within one or more
#' bounding boxes, paginating each query and merging/deduplicating results
#' (by case_id) across boxes. There is no native spatial filter in this API
#' -- xlong/ylat range filters are the closest equivalent, which is exactly
#' what a bounding box needs.
fetch_uswtdb <- function(bboxes_wgs84) {
  logger.info(paste("Querying USWTDB API across", length(bboxes_wgs84), "region(s)"))

  results <- purrr::map(bboxes_wgs84, fetch_uswtdb_bbox)
  results <- purrr::compact(results)
  if (length(results) == 0) {
    logger.info("No turbines found in query region(s)")
    return(NULL)
  }

  turbines <- dplyr::bind_rows(results)
  turbines <- turbines[!duplicated(turbines$case_id), ]
  if (nrow(turbines) == 0) {
    logger.info("No turbines found in query region(s)")
    return(NULL)
  }

  turbines_sf <- sf::st_as_sf(turbines, coords = c("xlong", "ylat"), crs = 4326, remove = FALSE)
  logger.info(paste("Found", nrow(turbines_sf), "unique turbine(s) across query region(s)"))
  turbines_sf
}

#' Query one bounding box against USWTDB, paginating with limit/offset until
#' a page comes back shorter than the page size (i.e. the end of results).
fetch_uswtdb_bbox <- function(bbox_wgs84, page_size = 1000) {
  filter_qs <- sprintf(
    "xlong=gte.%f&xlong=lte.%f&ylat=gte.%f&ylat=lte.%f&select=case_id,p_name,p_year,t_state,xlong,ylat,t_hh,t_rd",
    bbox_wgs84["xmin"], bbox_wgs84["xmax"], bbox_wgs84["ymin"], bbox_wgs84["ymax"]
  )

  pages <- list()
  offset <- 0
  repeat {
    url <- sprintf("%s?%s&limit=%d&offset=%d", USWTDB_QUERY_URL, filter_qs, page_size, offset)

    resp <- tryCatch(httr2::request(url) %>% httr2::req_perform(), error = function(e) {
      logger.error(paste("USWTDB request failed:", conditionMessage(e)))
      NULL
    })
    if (is.null(resp)) break

    page <- tryCatch(httr2::resp_body_json(resp, simplifyVector = TRUE), error = function(e) {
      logger.error(paste("USWTDB response parsing failed:", conditionMessage(e)))
      NULL
    })
    n_page <- if (is.data.frame(page)) nrow(page) else length(page)
    if (is.null(page) || is.null(n_page) || n_page == 0) break

    pages[[length(pages) + 1]] <- page
    if (n_page < page_size) break
    offset <- offset + page_size
  }

  if (length(pages) == 0) return(NULL)
  dplyr::bind_rows(pages)
}

#' Resolve a providedAppFiles settingId to an actual, single file path.
#'
#' getAppFilePath()'s exact return contract is genuinely unclear from the
#' documentation available while writing this: one example uses its result
#' directly as a file path (`read.csv(getAuxiliaryFilePath("aux_A"))`),
#' while another concatenates a filename onto it
#' (`paste0(getAppFilePath("id"), "sample.txt")`), implying it returns the
#' containing folder instead. Rather than assume either, this helper
#' handles both: if the resolved path is a directory, it looks inside for
#' the single non-dotfile it should contain (each providedAppFiles folder
#' is meant to hold exactly one real file, alongside an optional `.keep`
#' placeholder -- see README's *Auxiliary files* section); if it's already
#' a file, it's returned as-is.
resolve_app_file <- function(setting_id) {
  path <- getAuxiliaryFilePath(setting_id)
  if (is.na(path) || !nzchar(path)) return(NA_character_)

  if (dir.exists(path)) {
    candidates <- list.files(path, full.names = TRUE)
    candidates <- candidates[!grepl("^\\.", basename(candidates))]
    if (length(candidates) == 0) return(NA_character_)
    if (length(candidates) > 1) {
      logger.warn(paste0(
        "providedAppFiles folder for '", setting_id, "' contains more than ",
        "one non-hidden file; using the first one found (", basename(candidates[1]), ")."
      ))
    }
    return(candidates[1])
  }

  path
}

#' Load the bundled GM-SEUS array extract. Shipped as a MoveApps fixed
#' auxiliary file (settingId "gmseus_arrays", declared in appspec.json's
#' providedAppFiles) rather than a hardcoded repo path, and resolved at
#' runtime via getAppFilePath() (see resolve_app_file() above for why that
#' resolution is done defensively) -- this is the platform-supported
#' mechanism for App-provided (as opposed to user-uploaded) auxiliary data,
#' and keeps the file's on-disk location an implementation detail of the
#' MoveApps SDK rather than something this code assumes. Small enough
#' (~19k features, slimmed to a handful of fields) to read in full every
#' run rather than needing a spatial pre-filter.
fetch_gmseus <- function(sdk) {
  logger.info("Loading bundled GM-SEUS array data")

  gmseus_path <- tryCatch(
    resolve_app_file(GMSEUS_AUX_SETTING_ID),
    error = function(e) {
      logger.error(paste(
        "Could not resolve GM-SEUS auxiliary file path via",
        "getAppFilePath():", conditionMessage(e)
      ))
      NA_character_
    }
  )

  if (is.na(gmseus_path) || !file.exists(gmseus_path)) {
    logger.error(paste0(
      "Bundled GM-SEUS auxiliary file ('", GMSEUS_AUX_SETTING_ID, "') not found",
      if (!is.na(gmseus_path)) paste0(" at '", gmseus_path, "'") else "", ". ",
      "Confirm data/auxiliary/user-files/provided-app-files/", GMSEUS_AUX_SETTING_ID,
      "/ contains exactly one file (regenerate it from a fresh GM-SEUS ",
      "release with data-raw/extract_gmseus_arrays.R if needed), and that ",
      "it's declared under providedAppFiles in appspec.json."
    ))
    return(NULL)
  }

  arrays <- tryCatch(sf::st_read(gmseus_path, quiet = TRUE), error = function(e) {
    logger.error(paste("GM-SEUS load failed:", conditionMessage(e)))
    NULL
  })
  if (is.null(arrays) || nrow(arrays) == 0) return(NULL)

  # GM-SEUS uses -9999 as a missing-data sentinel across many numeric
  # fields (confirmed present in instYrEst). Left unsanitized, this would
  # corrupt classify_temporal_overlap() (a "-9999" operational year would
  # misclassify nearly everything as post-operational) and inflate
  # solar_instYr_confidence_diff into meaningless multi-thousand-year values
  # instead of NA.
  arrays <- sanitize_gmseus_sentinels(arrays, cols = c("instYr", "instYrEst"))

  # Defensive geometry validation. A handful of invalid/empty/degenerate
  # geometries in this dataset previously caused st_is_within_distance() to
  # spuriously report EVERY array as "within distance" of every track --
  # likely because a spatial index (R-tree) built over even a few malformed
  # bounding boxes can have its pruning logic corrupted for the whole
  # dataset, not just the bad rows. Repair/drop those here at load time,
  # regardless of whether the extraction script already tried to (defense
  # in depth -- a corrupted bundled file should never be able to silently
  # break every overlap result again).
  n_before <- nrow(arrays)
  invalid_idx <- !sf::st_is_valid(arrays) | sf::st_is_empty(arrays)
  if (any(invalid_idx)) {
    logger.warn(paste(sum(invalid_idx), "invalid/empty solar array geometries found; repairing"))
    arrays <- sf::st_make_valid(arrays)
    # st_make_valid() can occasionally produce a GEOMETRYCOLLECTION (mixing
    # points/lines/polygons) for severely degenerate input rather than a
    # clean polygon -- extract just the polygonal parts, since that's all
    # overlap/distance testing needs.
    arrays <- sf::st_collection_extract(arrays, "POLYGON", warn = FALSE)
    arrays <- arrays[sf::st_is_valid(arrays) & !sf::st_is_empty(arrays), ]
    if (nrow(arrays) < n_before) {
      logger.warn(paste("Dropped", n_before - nrow(arrays),
                              "array(s) that remained invalid/empty after repair"))
    }
  }

  logger.info(paste("Loaded", nrow(arrays), "solar array(s) from bundled GM-SEUS extract"))
  arrays
}

#' Replace GM-SEUS's -9999 missing-data sentinel with NA in the given columns
sanitize_gmseus_sentinels <- function(x, cols) {
  for (col in cols) {
    if (col %in% names(x)) {
      vals <- x[[col]]
      vals[!is.na(vals) & vals <= -9000] <- NA
      x[[col]] <- vals
    }
  }
  x
}

#' Classify the temporal relationship between a track's date range and an
#' infrastructure item's operational year
classify_temporal_overlap <- function(track_start, track_end, operational_year) {
  if (is.na(operational_year)) return(NA_character_)
  op_start <- as.Date(sprintf("%d-01-01", operational_year))
  if (track_end < op_start) {
    "pre-operational"
  } else if (track_start >= op_start) {
    "post-operational"
  } else {
    "spanning"
  }
}

#' Thin a track's points for the overlap test only (NOT for quality metrics,
#' which should always reflect the full, untouched data). Systematic/even
#' subsampling down to approximately max_locations points. This is an
#' optional escape hatch for extremely high-frequency, long-duration tracks
#' where even the indexed overlap test becomes costly -- leave disabled by
#' default since it trades a small chance of missing a brief close pass
#' between two fixes for speed.
thin_points_for_overlap <- function(track_pts, max_locations) {
  n <- nrow(track_pts)
  if (n <= max_locations) return(track_pts)
  idx <- unique(floor(seq(1, n, length.out = max_locations)))
  track_pts[idx, ]
}

#' Identify distinct "visit bouts" to a buffer from a chronologically-sorted
#' sequence of tested fixes and their in-buffer status, to distinguish
#' repeat visits from one long stay.
#'
#' Definition used here: a bout is a maximal run of temporally-consecutive
#' tested fixes that are each individually within the buffer. A bout ends
#' the moment a fix in the sequence is recorded OUTSIDE the buffer -- that's
#' direct evidence the animal left, so the next in-buffer fix (whenever it
#' occurs) starts a new bout. This is deliberately sequence-based rather
#' than time-threshold-based: it does not independently split a bout just
#' because of a large time gap between two in-buffer fixes if no
#' out-of-buffer fix was recorded in between -- with no fixes recorded
#' during that gap, there's no direct evidence the animal actually left, so
#' treating it as one continuous stay is the more conservative reading of
#' the available data (rather than inventing a time-threshold to split on).
#'
#' `in_buffer_sorted` and `timestamps_sorted` must both be pre-sorted into
#' chronological order and aligned 1:1 (see summarize_track, which sorts
#' overlap_pts by time before either is computed).
compute_visit_bouts <- function(in_buffer_sorted, timestamps_sorted) {
  if (length(in_buffer_sorted) == 0 || !any(in_buffer_sorted)) {
    return(list(n_bouts = 0L, longest_hours = NA_real_))
  }

  idx_in <- which(in_buffer_sorted)
  # A new bout starts at the first in-buffer fix, and at any subsequent
  # in-buffer fix that isn't immediately preceded (in the overall fix
  # sequence) by the previous in-buffer fix -- i.e. at least one
  # out-of-buffer fix intervened.
  new_bout <- c(TRUE, diff(idx_in) > 1)
  bout_id <- cumsum(new_bout)

  bout_durations_hours <- vapply(
    split(timestamps_sorted[idx_in], bout_id),
    function(t) as.numeric(difftime(max(t), min(t), units = "hours")),
    numeric(1)
  )

  list(n_bouts = length(bout_durations_hours), longest_hours = max(bout_durations_hours))
}

#' Compute overlap + exposure-intensity metrics for one track
summarize_track <- function(track_pts, track_id, study_name, wind_pts, solar_polys,
                             buffer_distance_m, enable_thinning = FALSE,
                             thinning_max_locations = 5000, height_field = NA_character_,
                             height_is_agl = NA) {

  # A track can end up with zero rows here if every one of its locations had
  # missing/empty coordinates and was filtered out upstream (see rFunction).
  # Report it explicitly rather than letting min()/max() on an empty vector
  # crash the whole run.
  if (nrow(track_pts) == 0) {
    logger.warn(paste("Track", track_id, "has zero valid locations after filtering; skipping"))
    return(tibble::tibble(
      study_name = study_name, track_id = as.character(track_id),
      n_locations = 0L, track_start = as.Date(NA), track_end = as.Date(NA),
      duration_days = NA_real_, median_fix_interval_hours = NA_real_,
      n_days_monitored = NA_integer_,
      overlaps_wind = NA, n_turbines_overlap = NA_integer_,
      n_wind_points_in_buffer = NA_integer_, n_turbines_track_only = NA_integer_,
      pct_wind_points_in_buffer = NA_real_, pct_wind_days_in_buffer = NA_real_,
      n_wind_visit_bouts = NA_integer_, wind_longest_buffer_bout_hours = NA_real_,
      nearest_turbine_dist_m = NA_real_, wind_dist_median_m = NA_real_,
      wind_temporal_relation = NA_character_,
      wind_height_field_used = NA_character_, wind_height_is_agl = NA,
      n_wind_points_in_rotor_zone = NA_integer_,
      wind_height_min_m = NA_real_, wind_height_median_m = NA_real_, wind_height_max_m = NA_real_,
      overlaps_solar = NA, n_solar_arrays_overlap = NA_integer_,
      n_solar_points_in_buffer = NA_integer_, n_solar_arrays_track_only = NA_integer_,
      pct_solar_points_in_buffer = NA_real_, pct_solar_days_in_buffer = NA_real_,
      n_solar_visit_bouts = NA_integer_, solar_longest_buffer_bout_hours = NA_real_,
      nearest_solar_dist_m = NA_real_, solar_dist_median_m = NA_real_,
      solar_temporal_relation = NA_character_,
      solar_instYr_confidence_diff = NA_real_
    ))
  }

  timestamps <- move2::mt_time(track_pts)
  n_locations <- nrow(track_pts)
  track_start <- as.Date(min(timestamps))
  track_end   <- as.Date(max(timestamps))
  duration_days <- as.numeric(difftime(track_end, track_start, units = "days"))

  fix_intervals_h <- as.numeric(diff(sort(timestamps)), units = "hours")
  median_fix_interval_h <- if (length(fix_intervals_h) > 0) stats::median(fix_intervals_h) else NA_real_

  # Quality metrics above always use the full, unthinned track. Thinning
  # (if enabled) affects both the point-based overlap test and the track
  # line built below, consistently.
  overlap_pts <- if (enable_thinning) {
    thin_points_for_overlap(track_pts, thinning_max_locations)
  } else {
    track_pts
  }

  # Sort chronologically once, here -- track_line, the days-monitored
  # count, and the visit-bout detection below all depend on a consistent
  # time order, so this avoids re-sorting (and risking an inconsistent
  # order) in multiple places.
  overlap_pts <- overlap_pts[order(move2::mt_time(overlap_pts)), ]
  overlap_timestamps <- move2::mt_time(overlap_pts)

  # Distinct calendar days represented by the tested point set (post-
  # thinning if enabled) -- used both to report monitoring coverage and as
  # the denominator for the wind/solar "days in buffer" percentages below.
  n_days_monitored <- length(unique(as.Date(overlap_timestamps)))

  # Build the track's chronological path as a line, for the "did the route
  # pass near infrastructure even though no single recorded fix landed in
  # the buffer" test. Requires >= 2 points; a single-fix track has no path
  # beyond the point itself, so this is left NULL for that case (handled by
  # summarize_infra_overlap).
  track_line <- if (nrow(overlap_pts) >= 2) {
    coords <- sf::st_coordinates(overlap_pts)[, c("X", "Y"), drop = FALSE]
    sf::st_sfc(sf::st_linestring(coords), crs = sf::st_crs(overlap_pts))
  } else {
    NULL
  }

  # Heights aligned 1:1 with overlap_pts, for the wind height check only
  # (wind is the clear collision-risk use case; solar ground arrays don't
  # have an equivalent vertical hazard zone). NULL if height analysis is
  # off or no recognized height column was found upstream.
  heights_m <- NULL
  if (!is.na(height_field) && height_field %in% names(overlap_pts)) {
    heights_m <- suppressWarnings(as.numeric(sf::st_drop_geometry(overlap_pts)[[height_field]]))
  }

  # --- Wind ---
  # USWTDB provides a single operational-year field (p_year) with no
  # independent second estimate, so no est_year_field here.
  wind_overlap <- summarize_infra_overlap(
    overlap_pts, track_line, wind_pts, buffer_distance_m, year_field = "p_year",
    track_start = track_start, track_end = track_end,
    heights_m = heights_m, height_is_agl = height_is_agl,
    hub_height_field = "t_hh", rotor_diameter_field = "t_rd"
  )

  # --- Solar ---
  # GM-SEUS's instYr already has gaps backfilled from instYrEst (an
  # independent Landsat-derived estimate); passing instYrEst here surfaces
  # how much the two diverge, as a soft confidence signal -- not a claim
  # that instYr is "estimated" vs "sourced," which the data doesn't cleanly
  # distinguish. No height analysis for solar -- see rationale above.
  solar_overlap <- summarize_infra_overlap(
    overlap_pts, track_line, solar_polys, buffer_distance_m, year_field = "instYr",
    track_start = track_start, track_end = track_end,
    est_year_field = "instYrEst"
  )

  # --- Days-in-buffer and visit-bout metrics, wind and solar ---
  # Both derived from summarize_infra_overlap()'s in_buffer_flags, which is
  # aligned 1:1 with overlap_pts (already sorted chronologically above).
  n_points_tested <- nrow(overlap_pts)

  wind_days_in_buffer <- length(unique(as.Date(overlap_timestamps[wind_overlap$in_buffer_flags])))
  wind_bouts <- compute_visit_bouts(wind_overlap$in_buffer_flags, overlap_timestamps)

  solar_days_in_buffer <- length(unique(as.Date(overlap_timestamps[solar_overlap$in_buffer_flags])))
  solar_bouts <- compute_visit_bouts(solar_overlap$in_buffer_flags, overlap_timestamps)

  pct_wind_points_in_buffer <- if (n_points_tested > 0) 100 * wind_overlap$n_points_in_buffer / n_points_tested else NA_real_
  pct_solar_points_in_buffer <- if (n_points_tested > 0) 100 * solar_overlap$n_points_in_buffer / n_points_tested else NA_real_
  pct_wind_days_in_buffer <- if (n_days_monitored > 0) 100 * wind_days_in_buffer / n_days_monitored else NA_real_
  pct_solar_days_in_buffer <- if (n_days_monitored > 0) 100 * solar_days_in_buffer / n_days_monitored else NA_real_

  tibble::tibble(
    study_name = study_name,
    track_id = as.character(track_id),
    n_locations = n_locations,
    track_start = track_start,
    track_end = track_end,
    duration_days = duration_days,
    median_fix_interval_hours = median_fix_interval_h,
    n_days_monitored = n_days_monitored,
    overlaps_wind = wind_overlap$overlaps,
    n_turbines_overlap = wind_overlap$n_overlap,
    n_wind_points_in_buffer = wind_overlap$n_points_in_buffer,
    n_turbines_track_only = wind_overlap$n_track_only,
    pct_wind_points_in_buffer = pct_wind_points_in_buffer,
    pct_wind_days_in_buffer = pct_wind_days_in_buffer,
    n_wind_visit_bouts = wind_bouts$n_bouts,
    wind_longest_buffer_bout_hours = wind_bouts$longest_hours,
    nearest_turbine_dist_m = wind_overlap$nearest_dist_m,
    wind_dist_median_m = wind_overlap$dist_median_m,
    wind_temporal_relation = wind_overlap$temporal_relation,
    wind_height_field_used = if (!is.null(heights_m)) height_field else NA_character_,
    wind_height_is_agl = if (!is.null(heights_m)) height_is_agl else NA,
    n_wind_points_in_rotor_zone = wind_overlap$n_points_in_rotor_zone,
    wind_height_min_m = wind_overlap$height_min_m,
    wind_height_median_m = wind_overlap$height_median_m,
    wind_height_max_m = wind_overlap$height_max_m,
    overlaps_solar = solar_overlap$overlaps,
    n_solar_arrays_overlap = solar_overlap$n_overlap,
    n_solar_points_in_buffer = solar_overlap$n_points_in_buffer,
    n_solar_arrays_track_only = solar_overlap$n_track_only,
    pct_solar_points_in_buffer = pct_solar_points_in_buffer,
    pct_solar_days_in_buffer = pct_solar_days_in_buffer,
    n_solar_visit_bouts = solar_bouts$n_bouts,
    solar_longest_buffer_bout_hours = solar_bouts$longest_hours,
    nearest_solar_dist_m = solar_overlap$nearest_dist_m,
    solar_dist_median_m = solar_overlap$dist_median_m,
    solar_temporal_relation = solar_overlap$temporal_relation,
    solar_instYr_confidence_diff = solar_overlap$year_estimate_max_diff
  )
}

#' Shared overlap/distance/temporal-classification logic for one
#' infrastructure layer (wind points or solar polygons).
#'
#' Uses spatially-indexed predicates instead of materializing a buffered
#' union-of-points polygon or a dense pairwise distance matrix, so this
#' scales to tracks with very large numbers of locations:
#'  - point-based overlap: st_is_within_distance(points, infra) -- for each
#'    RECORDED FIX, is it within the buffer distance of any infrastructure
#'    feature? This is direct evidence: the animal was actually detected
#'    there.
#'  - track-based overlap: st_is_within_distance(infra, track_line) -- does
#'    the interpolated path BETWEEN consecutive fixes come within the
#'    buffer distance of infrastructure that no single recorded fix landed
#'    in? This is inferred evidence -- with coarse fix intervals, the
#'    animal may have passed close to a facility between two GPS fixes
#'    without either fix itself falling inside the buffer. Facilities
#'    caught only by this test (not by any actual point) are reported
#'    separately as "track only," so point-confirmed and path-inferred
#'    proximity are never conflated.
#'  - nearest distance: st_nearest_feature(points, infra) finds each
#'    recorded point's nearest infra feature via the index (O(n log m)),
#'    then distances are computed only for those matched pairs (O(n))
#'    rather than all n*m pairs. This remains point-based (not path-based).
#'
#' `est_year_field`, if supplied, names a second, independently-derived year
#' field (e.g. GM-SEUS's `instYrEst`) to compare against `year_field` -- the
#' divergence between the two is reported as a soft confidence signal rather
#' than a hard flag, since a large gap doesn't necessarily mean either value
#' is "wrong," just less corroborated.
#'
#' `heights_m` (aligned 1:1 with `track_pts`), if supplied, enables height
#' reporting for points within the buffer. Only when `height_is_agl` is TRUE
#' AND `infra` has both `hub_height_field` and `rotor_diameter_field`
#' columns is a rotor-swept-zone pass/fail classification computed
#' (`n_points_in_rotor_zone`) -- otherwise only summary min/median/max
#' height is reported, deliberately without any zone classification, since
#' non-AGL height (ellipsoid/MSL) can't be safely compared to a
#' ground-relative hazard zone without a DEM-based correction this App does
#' not perform.
summarize_infra_overlap <- function(track_pts, track_line, infra, buffer_distance_m,
                                     year_field, track_start, track_end, est_year_field = NULL,
                                     heights_m = NULL, height_is_agl = NULL,
                                     hub_height_field = NULL, rotor_diameter_field = NULL) {
  empty <- list(overlaps = FALSE, n_overlap = 0L, nearest_dist_m = NA_real_,
                dist_median_m = NA_real_,
                temporal_relation = NA_character_, year_estimate_max_diff = NA_real_,
                n_points_in_buffer = 0L, n_track_only = 0L,
                in_buffer_flags = logical(nrow(track_pts)),
                n_points_in_rotor_zone = NA_integer_,
                height_min_m = NA_real_, height_median_m = NA_real_, height_max_m = NA_real_)
  if (is.null(infra) || nrow(infra) == 0 || nrow(track_pts) == 0) return(empty)

  # Point-based evidence: which infra features have >=1 recorded fix within
  # the buffer, and how many fixes does that represent overall (a fix
  # counted once even if it's near multiple infra features, since this
  # metric answers "how much of the animal's recorded history was inside
  # the buffer," not "how many feature-fix pairs exist").
  pts_within <- sf::st_is_within_distance(track_pts, infra, dist = buffer_distance_m)
  n_points_in_buffer <- sum(lengths(pts_within) > 0)
  point_infra_idx <- sort(unique(unlist(pts_within)))

  # Track-based evidence: infra features the interpolated path comes within
  # the buffer of, regardless of whether any point also did.
  track_infra_idx <- integer(0)
  if (!is.null(track_line)) {
    line_within <- sf::st_is_within_distance(infra, track_line, dist = buffer_distance_m)
    track_infra_idx <- which(lengths(line_within) > 0)
  }

  # "Track only": infra features caught by the path but not by any actual
  # recorded fix -- inferred-but-unconfirmed proximity.
  n_track_only <- length(setdiff(track_infra_idx, point_infra_idx))

  overlap_idx <- union(point_infra_idx, track_infra_idx)
  hits <- infra[overlap_idx, ]
  n_overlap <- length(overlap_idx)

  nearest_idx <- sf::st_nearest_feature(track_pts, infra)
  point_to_nearest_dist <- suppressWarnings(as.numeric(
    sf::st_distance(track_pts, infra[nearest_idx, ], by_element = TRUE)
  ))
  nearest_dist_m <- if (length(point_to_nearest_dist) > 0) {
    min(point_to_nearest_dist, na.rm = TRUE)
  } else {
    NA_real_
  }
  if (!is.finite(nearest_dist_m)) nearest_dist_m <- NA_real_

  # Median (not just nearest) distance across ALL tested fixes -- a
  # complement to nearest_dist_m that reflects typical, not best-case,
  # proximity across the whole track.
  dist_median_m <- if (length(point_to_nearest_dist) > 0) {
    stats::median(point_to_nearest_dist, na.rm = TRUE)
  } else {
    NA_real_
  }
  if (!is.finite(dist_median_m)) dist_median_m <- NA_real_

  temporal_relation <- NA_character_
  year_estimate_max_diff <- NA_real_

  if (n_overlap > 0 && year_field %in% names(hits)) {
    years <- suppressWarnings(as.integer(hits[[year_field]]))
    relations <- purrr::map_chr(years, ~classify_temporal_overlap(track_start, track_end, .x))
    relations <- relations[!is.na(relations)]
    if (length(relations) > 0) {
      # If the track spans multiple infrastructure items with different
      # operational years, report the mixed case explicitly rather than
      # silently picking one.
      temporal_relation <- if (length(unique(relations)) == 1) unique(relations) else "mixed"
    }

    if (!is.null(est_year_field) && est_year_field %in% names(hits)) {
      years_est <- suppressWarnings(as.integer(hits[[est_year_field]]))
      diffs <- abs(years - years_est)
      diffs <- diffs[!is.na(diffs)]
      if (length(diffs) > 0) year_estimate_max_diff <- max(diffs)
    }
  }

  # --- Height (wind-only; NULL heights_m for solar skips all of this) ---
  n_points_in_rotor_zone <- NA_integer_
  height_min_m <- NA_real_
  height_median_m <- NA_real_
  height_max_m <- NA_real_

  if (!is.null(heights_m)) {
    in_buffer_idx <- which(lengths(pts_within) > 0)
    valid_heights <- heights_m[in_buffer_idx]
    valid_heights <- valid_heights[!is.na(valid_heights)]

    if (length(valid_heights) > 0) {
      height_min_m <- min(valid_heights)
      height_median_m <- stats::median(valid_heights)
      height_max_m <- max(valid_heights)

      has_turbine_geometry <- !is.null(hub_height_field) && hub_height_field %in% names(infra) &&
        !is.null(rotor_diameter_field) && rotor_diameter_field %in% names(infra)

      if (isTRUE(height_is_agl) && has_turbine_geometry) {
        # Per point within the buffer, check whether its (true AGL) height
        # falls within the rotor-swept zone of ANY nearby turbine --
        # hub_height +/- rotor_radius. Points near turbines with unknown
        # (NA) hub height/rotor diameter simply can't be classified and
        # don't count either way (na.rm = TRUE below).
        in_zone <- purrr::map_lgl(in_buffer_idx, function(i) {
          h <- heights_m[i]
          if (is.na(h)) return(FALSE)
          nearby_idx <- pts_within[[i]]
          if (length(nearby_idx) == 0) return(FALSE)
          nearby <- infra[nearby_idx, ]
          hh <- suppressWarnings(as.numeric(nearby[[hub_height_field]]))
          rd <- suppressWarnings(as.numeric(nearby[[rotor_diameter_field]]))
          zone_min <- hh - rd / 2
          zone_max <- hh + rd / 2
          any(h >= zone_min & h <= zone_max, na.rm = TRUE)
        })
        n_points_in_rotor_zone <- sum(in_zone)
      }
      # When height_is_agl is FALSE (ellipsoid/MSL) or turbine geometry is
      # unavailable, n_points_in_rotor_zone stays NA -- deliberately no
      # classification is attempted, only the raw height summary above.
    }
  }

  list(
    overlaps = n_overlap > 0,
    n_overlap = n_overlap,
    nearest_dist_m = nearest_dist_m,
    dist_median_m = dist_median_m,
    temporal_relation = temporal_relation,
    year_estimate_max_diff = year_estimate_max_diff,
    n_points_in_buffer = n_points_in_buffer,
    n_track_only = n_track_only,
    in_buffer_flags = lengths(pts_within) > 0,
    n_points_in_rotor_zone = n_points_in_rotor_zone,
    height_min_m = height_min_m,
    height_median_m = height_median_m,
    height_max_m = height_max_m
  )
}
