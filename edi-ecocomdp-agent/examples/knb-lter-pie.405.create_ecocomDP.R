# -----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-pie.405" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.337" (also archived in EDI)
# 
# Arguments:
#
# path        Where the ecocomDP tables will be written
# source_id   Identifier of the source dataset
# derived_id  Identifier of the derived dataset
# url         The URL by which the derived tables and metadata can be accessed 
#             by a data repository. This argument is used when automating the 
#             repository publication step, but not used when manually 
#             publishing.
#
# Value:
#
# tables      (.csv) ecocomDP tables
# metadata    (.xml) EML metadata for tables
# 
# Details:
#             This function facilitates automated updates to the derived 
#             "edi.337" whenever new data are added to the source 
#             "knb-lter-pie.405". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-pie.405". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-pie.405":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-pie&identifier=405
# Landing page to derived dataset "edi.337":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=337
# -----------------------------------------------------------------------------

# Libraries used by this function

library(ecocomDP)
library(xml2)
library(magrittr)
library(data.table)
library(lubridate)
library(tidyr)
library(dplyr)
library(EDIutils)       # remotes::install_github("EDIorg/EDIutils")
library(taxonomyCleanr) # remotes::install_github("EDIorg/taxonomyCleanr")

create_ecocomDP <- function(path,
                            source_id, 
                            derived_id, 
                            url = NULL) {
  
  # Read source dataset -------------------------------------------------------
  
  # The source dataset is about zooplankton communities within the Plum Island
  # Sound Esturary. Observations are made at discrete stations. Add data are
  # contained within one table.
  
  # Read the source dataset from EDI
  
  eml <- EDIutils::api_read_metadata(source_id)
  data <- EDIutils::read_tables(
    eml = eml, 
    strip.white = TRUE,
    na.strings = "",
    convert.missing.value = TRUE, 
    add.units = TRUE)
  
  zoops <- data$`EST-PR-SO-ZoopSurv.csv`
  
  # Flatten the source dataset ------------------------------------------------
  
  wide <- zoops
  
  # Convert wide format to "flat" format
  
  wide <- wide %>% rename(value = ABUNDANCE, unit = unit_ABUNDANCE)
  wide$variable_name <- "ABUNDANCE"
  flat <- wide
  
  # Add columns for the observation table -------------------------------------
  
  flat <- dplyr::rename(flat, datetime = DATE)
  flat$datetime <- lubridate::ymd(flat$datetime)
  
  # Surveys were conducted in the spring and later summer of each year
  
  flat <- create_event_id(
    x = flat, 
    grps = list(
      list(start = "04-01", end = "07-01"),
      list(start = "08-01", end = "10-01")))
  
  # Observations are made at distinct locations
  
  flat$location_id <- flat %>% group_by(`STATION ID`) %>% group_indices()
  
  # Each row of the flattened source dataset represents an observation
  
  flat$observation_id <- seq(nrow(flat))
  
  # Add columns for the location table ----------------------------------------
  
  # Lats and lons are provided for each station, but there's variance in these
  # values over time. We'll include the averages for the location table and 
  # move the exact measurements to the location ancillary table.
  
  lat <- flat %>% 
    dplyr::group_by(`STATION ID`) %>% 
    dplyr::summarise(latitude = mean(LAT))
  flat <- dplyr::left_join(flat, lat, by = "STATION ID")
  
  lon <- flat %>% 
    dplyr::group_by(`STATION ID`) %>% 
    dplyr::summarise(longitude = mean(LON))
  flat <- dplyr::left_join(flat, lon, by = "STATION ID")
  
  # Add columns for the taxon table -------------------------------------------
  
  # Taxonomic names are listed but with the species sex embedded in the name.
  # Extract the name and move the original name+sex to observation ancillary
  
  flat$taxon_name <- trimws(
    stringr::str_extract(flat$TAXON, "^.+(?=[:blank:]*\\(.+\\))"))
  
  flat$taxon_id <- flat %>% group_by(taxon_name) %>% group_indices()
  
  # While not required, resolving taxonomic entities to an authority system 
  # improves the discoverability and interoperability of the ecocomDP dataset. 
  # We can resolve taxa by sending names through taxonomyCleanr for direct 
  # matches against the Integrated Taxonomic Information System 
  # (ITIS; https://www.itis.gov/).
  
  taxa_resolved <- taxonomyCleanr::resolve_sci_taxa(
    x = unique(flat$taxon_name),
    data.sources = 3)
  
  taxa_resolved <- taxa_resolved %>%
    select(taxa, rank, authority, authority_id) %>%
    rename(taxon_rank = rank,
           taxon_name = taxa,
           authority_system = authority,
           authority_taxon_id = authority_id)
  
  flat <- left_join(flat, taxa_resolved, by = "taxon_name")
  
  # Add columns for the dataset_summary table ---------------------------------
  
  dates <- flat$datetime %>% stats::na.omit() %>% sort()
  
  # Use the calc_*() helper functions for consistency
  
  flat$package_id <- derived_id
  flat$original_package_id <- source_id
  flat$length_of_survey_years <- ecocomDP::calc_length_of_survey_years(dates)
  flat$number_of_years_sampled <- ecocomDP::calc_number_of_years_sampled(dates)
  flat$std_dev_interval_betw_years <- 
    ecocomDP::calc_std_dev_interval_betw_years(dates)
  flat$max_num_taxa <- length(unique(flat$taxon_name))
  flat$geo_extent_bounding_box_m2 <- 
    ecocomDP::calc_geo_extent_bounding_box_m2(
      west = min(flat$longitude, na.rm = TRUE), 
      east = max(flat$longitude, na.rm = TRUE), 
      north = max(flat$latitude, na.rm = TRUE), 
      south = min(flat$latitude, na.rm = TRUE))
  
  # Parse flat into ecocomDP tables -------------------------------------------
  
  # Each ecocomDP table has an associated "create" function. Begin with the 
  # core required tables.
  
  observation <- ecocomDP::create_observation(
    L0_flat = flat, 
    observation_id = "observation_id", 
    event_id = "event_id", 
    package_id = "package_id",
    location_id = "location_id", 
    datetime = "datetime", 
    taxon_id = "taxon_id", 
    variable_name = "variable_name",
    value = "value",
    unit = "unit")
  
  location <- ecocomDP::create_location(
    L0_flat = flat, 
    location_id = "location_id", 
    location_name = c("STATION ID"), 
    latitude = "latitude", 
    longitude = "longitude")
  
  taxon <- ecocomDP::create_taxon(
    L0_flat = flat, 
    taxon_id = "taxon_id", 
    taxon_rank = "taxon_rank", 
    taxon_name = "taxon_name", 
    authority_system = "authority_system", 
    authority_taxon_id = "authority_taxon_id")
  
  dataset_summary <- ecocomDP::create_dataset_summary(
    L0_flat = flat, 
    package_id = "package_id", 
    original_package_id = "original_package_id", 
    length_of_survey_years = "length_of_survey_years",
    number_of_years_sampled = "number_of_years_sampled", 
    std_dev_interval_betw_years = "std_dev_interval_betw_years", 
    max_num_taxa = "max_num_taxa", 
    geo_extent_bounding_box_m2 = "geo_extent_bounding_box_m2")
  
  # Create the ancillary ecocomDP tables. These are optional, but should be 
  # included if possible.
  
  observation_ancillary <- ecocomDP::create_observation_ancillary(
    L0_flat = flat,
    observation_id = "observation_id", 
    variable_name = c("DIST", "SAMPLE NAME", "TIME", "TEMP", "SAL", "COND",
                      "COUNT START", "COUNT END", "COUNT DIFF", "TOW TIME",
                      "VOLUME", "SIZE FRACTION", "SUBSAMPLE FRAC", 
                      "NUMBER COUNTED", "NUMBERperTOW", "TAXON", "LAT", "LON"),
    unit = c("unit_DIST", "unit_TEMP", "unit_SAL", "unit_COND",
             "unit_COUNT START", "unit_COUNT END", "unit_COUNT DIFF", 
             "unit_TOW TIME", "unit_VOLUME", "unit_SUBSAMPLE FRAC", 
             "unit_NUMBER COUNTED", "unit_NUMBERperTOW", "unit_LAT", 
             "unit_LON"))
  
  location_ancillary <- ecocomDP::create_location_ancillary(
    L0_flat = flat,
    location_id = "location_id",
    variable_name = c("STATION NAME KM", "SITE"))
  
  # Create the variable_mapping table. This is optional but highly recommended 
  # as it provides unambiguous definitions to variables and facilitates 
  # integration with other ecocomDP datasets.
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary,
    location_ancillary = location_ancillary)
  
  i <- variable_mapping$variable_name == 'ABUNDANCE'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'The density, or more precisely, the volumetric count density of entities per unit volume.'
  variable_mapping$mapped_label[i] <- 'Number Volumetric Density'
  
  i <- variable_mapping$variable_name == 'DIST'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001710'
  variable_mapping$mapped_label[i] <- 'distance'
  
  i <- variable_mapping$variable_name == 'SAMPLE NAME'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/materialSampleID'
  variable_mapping$mapped_label[i] <- 'materialSampleID'
  
  i <- variable_mapping$variable_name == 'TIME'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventTime'
  variable_mapping$mapped_label[i] <- 'eventTime'
  
  i <- variable_mapping$variable_name == 'TEMP'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001559'
  variable_mapping$mapped_label[i] <- 'estuary water temperature'
  
  i <- variable_mapping$variable_name == 'SAL'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001164'
  variable_mapping$mapped_label[i] <- 'Water Salinity'
  
  i <- variable_mapping$variable_name == 'TOW TIME'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002953'
  variable_mapping$mapped_label[i] <- 'sample measurement period'
  
  i <- variable_mapping$variable_name == 'VOLUME'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002225'
  variable_mapping$mapped_label[i] <- 'water sample volume'
  
  i <- variable_mapping$variable_name == 'NUMBER COUNTED'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/individualCount'
  variable_mapping$mapped_label[i] <- 'individualCount'
  
  i <- variable_mapping$variable_name == 'NUMBERperTOW'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/individualCount'
  variable_mapping$mapped_label[i] <- 'individualCount'
  
  i <- variable_mapping$variable_name == 'SITE'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://purl.org/dc/terms/Location'
  variable_mapping$mapped_label[i] <- 'Location'
  
  i <- variable_mapping$variable_name == 'LAT'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'decimalLatitude'
  variable_mapping$mapped_label[i] <- 'http://rs.tdwg.org/dwc/terms/decimalLatitude'
  
  i <- variable_mapping$variable_name == 'LON'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/decimalLongitude'
  variable_mapping$mapped_label[i] <- 'decimalLongitude'
  
  # Write tables to file
  
  ecocomDP::write_tables(
    path = path, 
    observation = observation, 
    location = location,
    taxon = taxon,
    dataset_summary = dataset_summary, 
    observation_ancillary = observation_ancillary,
    location_ancillary = location_ancillary, 
    variable_mapping = variable_mapping)
  
  # Validate tables -----------------------------------------------------------
  
  # Validation checks ensure the derived set of tables comply with the ecocomDP
  # model. Any issues at this point 
  # should be addressed in the lines of code above, the tables rewritten, and 
  # another round of validation, to be certain the fix worked.
  
  issues <- ecocomDP::validate_data(path = path)
  
  # Create metadata -----------------------------------------------------------
  
  # Before publishing the derived ecocomDP dataset, we need to describe it. The 
  # create_eml() function does this all for us. It knows the structure of the 
  # ecocomDP model and applies standardized table descriptions and mixes in 
  # important elements of the source dataset metadata for purposes of 
  # communication and provenance tracking.
  
  # Convert "dataset level keywords" listed in the source to "dataset level 
  # annotations" in the derived. The predicate "is about" is used, which 
  # results in an annotation that reads "This dataset is about 'species 
  # abundance'", "This dataset is about 'Population'", etc. All source datasets
  # involving a human induced manipulative experiment, not a natural 
  # disturbance/experiment, should include the "Manipulative experiment" 
  # annotation below to enable searching on this term.
  
  dataset_annotations <- c(
    `ecological community` = 
      "http://purl.obolibrary.org/obo/PCO_0000002")
  
  # Add contact information for the author of this script and dataset
  
  additional_contact <- data.frame(
    givenName = 'Colin',
    surName = 'Smith',
    organizationName = 'Environmental Data Initiative',
    electronicMailAddress = 'ecocomdp@gmail.com',
    stringsAsFactors = FALSE)
  
  # Create EML metadata
  
  eml <- ecocomDP::create_eml(
    path = path,
    source_id = source_id,
    derived_id = derived_id,
    is_about = dataset_annotations,
    script = "create_ecocomDP.R",
    script_description = 
      "A function for converting knb-lter-pie.405 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
  
}








#' Create event_id from groups of datetime
#'
#' @param x (data.frame) Data frame with a column named "datetime" and containing "Date" or "POSIXct POSIXt" values. This function does not work for values of the YYYY format.
#' @param grps (named list) A list of periods defining the temporal bounds of an annually recurring survey/event. Each period must have a "start" and "end" month-day with values of the format "MM-DD".
#'
#' @return (data.frame) \code{x} with an added event_id column
#' 
#' @note \code{grps} "start" and "end" values are interpreted as "get all values >= start and <= end".
#' 
#' @examples 
#' 
#' # Read dataset from EDI
#' 
#' eml <- EDIutils::api_read_metadata("knb-lter-knz.69.18")
#' data <- EDIutils::read_tables(
#'   eml = eml, 
#'   strip.white = TRUE,
#'   na.strings = "",
#'   convert.missing.value = TRUE, 
#'   add.units = TRUE)[[1]]
#' 
#' # Create datetime column from components and parse to object of class "Date"
#' 
#' data <- data %>% tidyr::unite(col = "datetime", RecYear, RecMonth, RecDay, sep = "-")
#' data$datetime <- lubridate::ymd(data$datetime)
#' 
#' # Subset data for examples
#' 
#' data2 <- data %>%  dplyr::filter(datetime >= lubridate::ymd("1991-01-01"))
#' 
#' # EXAMPLE A: All datetime values fall within defined groups
#' 
#' res <- create_event_id(
#'   x = data2, 
#'   grps = list(
#'     list(start = "05-01", end = "07-15"),
#'     list(start = "07-16", end = "09-30")))
#' 
#' str(res) # event_id has been added
#' View(res %>% dplyr::select(datetime, event_id) %>% dplyr::distinct()) # Verify result
#' 
#' # EXAMPLE B: Not all datetime values fall within defined groups. We want a create_ecocomDP() to fail if some #' data2 are not being accounted for.
#' 
#' res <- create_event_id(
#'   x = data2, 
#'   grps = list(
#'     list(start = "05-01", end = "07-15"),
#'     list(start = "07-16", end = "08-01")))
#' 
#' # EXAMPLE C: Early years of the dataset use differnt survey periods than in later years. In this case we #' split the dataset, run create_event_id for both and update the event_id values for the second period.
#' 
#' data1 <- data %>%  dplyr::filter(datetime < lubridate::ymd("1991-01-01"))
#' data2 <- data %>%  dplyr::filter(datetime >= lubridate::ymd("1991-01-01"))
#' 
#' res1 <- create_event_id(
#'   x = data1, 
#'   grps = list(
#'     list(start = "01-01", end = "04-30"),
#'     list(start = "05-01", end = "07-15"),
#'     list(start = "07-16", end = "09-30"),
#'     list(start = "10-01", end = "12-31")))
#' 
#' res2 <- create_event_id(
#'   x = data2, 
#'   grps = list(
#'     list(start = "05-01", end = "07-15"),
#'     list(start = "07-16", end = "09-30")))
#' 
#' # Get max event_id from early years, add this value to event_id of later years and reunite dataset
#' 
#' data1_max_event_id <- max(as.numeric(res1$event_id))
#' res2$event_id <- as.character(as.numeric(res2$event_id) + data1_max_event_id)
#' data <- dplyr::bind_rows(res1, res2)
#' 
#' View(data %>% dplyr::select(datetime, event_id) %>% dplyr::distinct()) # Verify result
#'
create_event_id <- function(x, grps) {
  
  # Create separate datetime w/constant year for grouping by date periods
  x$true_year <- lubridate::year(x$datetime)
  x$y <- 2000
  x$m <- lubridate::month(x$datetime)
  x$d <- lubridate::day(x$datetime) 
  x <- tidyr::unite(data = x, col = "datetime2", y, m, d, sep = "-")
  x$datetime2 <- lubridate::ymd(x$datetime2)
  x$datetime2_period <- NA_character_
  
  # Create groups
  for (i in 1:length(grps)) {
    start <- lubridate::ymd(paste0("2000-", grps[[i]]$start))
    end <- lubridate::ymd(paste0("2000-", grps[[i]]$end))
    use_i <- x$datetime2 >= start & x$datetime2 <= end
    x$datetime2_period[use_i] <- paste0("period ", as.character(i))
  }
  
  # Stop if any datetime fall outside of the grouping. Stopping here prevents
  # the upload of errant data.
  if (any(is.na(x$datetime2_period))) {
    stop("Some observations fall outside of the defined survey periods. ",
         "Update your inputs to the 'grps' argument to include all ",
         "observations.")
  }
  
  # Assign event_id
  x$event_id <- x %>% 
    dplyr::group_by(true_year, datetime2_period) %>% 
    dplyr::group_indices() %>% as.character
  
  # Remove added content and return
  x <- x %>% 
    dplyr::select(-datetime2, -datetime2_period, -true_year)
  
  return(x)
}
