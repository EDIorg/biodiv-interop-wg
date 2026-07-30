# -----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-hbr.81" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.355" (also archived in EDI)
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
#             "edi.355" whenever new data are added to the source 
#             "knb-lter-hbr.81". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-hbr.81". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-hbr.81":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-hbr&identifier=81
# Landing page to derived dataset "edi.355":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=355
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
  
  # The source dataset is about bird communities across plots within the Hubbard
  # Brook Experimental Forest. The dataset consists 4 site/locationtables, each 
  # containing abundance estimates from annual surveys.
  
  # Read the source dataset from EDI
  
  eml <- EDIutils::api_read_metadata(source_id)
  data <- EDIutils::read_tables(
    eml = eml, 
    strip.white = TRUE,
    na.strings = "",
    convert.missing.value = TRUE, 
    add.units = TRUE)
  
  # Data reading issues, possibly a result of the 0x2c field delimiter listed in
  # the metadata, fails to recognize column names. Look for this issue, and 
  # assign column names from the EML if necessary.
  
  message("Fixing column names")
  for (tbl in names(data)) {
    cols <- colnames(data[[tbl]])
    defaultcols <- stringr::str_detect(cols, "^V[:digit:]+")
    if (any(defaultcols)) {
      datatable <- xml2::xml_find_all(eml, paste0(".//dataTable[.//objectName = '", tbl, "']"))
      attrs <- xml2::xml_text(xml2::xml_find_all(datatable, ".//attributeName"))
      cols[defaultcols] <- attrs
      colnames(data[[tbl]]) <- cols
      data[[tbl]] <- data[[tbl]][-1, ]
    }
  }
  
  # Join and flatten the source dataset ---------------------------------------
  
  # Gather each table then stack
  
  for (tbl in names(data)) {
    # Prepare for gather
    cols <- colnames(data[[tbl]])
    data[[tbl]]$site <- cols[1]
    unitcolumn <- which(stringr::str_detect(cols, "^unit_.+"))
    unit <- data[[tbl]][[unitcolumn[1]]][1]
    data[[tbl]]$unit <- unit
    cols <- colnames(data[[tbl]])
    data[[tbl]] <- dplyr::select(data[[tbl]], -dplyr::starts_with("unit_"))
    data[[tbl]]$taxon_name <- data[[tbl]][, stringr::str_detect(cols, "Bird Species")]
    data[[tbl]] <- dplyr::select(data[[tbl]], -dplyr::starts_with("Bird Species"))
    # Gather
    data[[tbl]] <- tidyr::pivot_longer(
      data = data[[tbl]], 
      cols = -c("site", "unit", "taxon_name"), 
      names_to = "datetime",
      values_to = "value")
  }
  # Stack
  birds <- data.table::rbindlist(data)
  
  # Prevent data loss. Abundances, though of numeric type, mix in categorical 
  # variables (i.e. t & tr = trace amounts of species). Move this code to it's 
  # own comment column to be listed in observation_ancillary.
  
  birds$comment <- NA_character_
  birds$comment[birds$value == "t"] <- "Species present but occurring at very low numbers (<0.5 individuals/10 ha)"
  birds$comment[birds$value == "tr"] <- "Species present but occurring at very low numbers (<0.5 individuals/10 ha)"
  birds$value[birds$value == "t"] <- NA
  birds$value[birds$value == "tr"] <- NA
  
  wide <- birds
  
  # Convert wide format to "flat" format
  
  flat <- wide
  flat$variable_name <- "count"
  
  # Add columns for the observation table -------------------------------------
  
  # Surveys (events) were conducted annually
  
  flat$event_id <- flat %>% dplyr::group_by(datetime) %>% dplyr::group_indices()
  flat <- flat %>% dplyr::arrange(event_id)
  
  # Observations are made in plots
  
  flat$location_id <- flat %>% dplyr::group_by(site) %>% dplyr::group_indices()
  
  # Each row of the flattened source dataset represents an observation of taxa 
  # abundance and should have a unique ID for reference
  
  flat$observation_id <- seq(nrow(flat))
  
  # Add columns for the location table ----------------------------------------
  
  # Get location coordinates from the metadata, clean up the location names, 
  # then join to flat.
  
  geocov <- geocov_2_dataframe(eml, xpath = ".//geographicCoverage", avg = TRUE)
  geocov$description[stringr::str_detect(geocov$description, "Hubbard Brook")] <- 
    "Hubbard Brook"
  geocov$description[stringr::str_detect(geocov$description, "Moosilauke")] <- 
    "Mount Moosilauke"
  geocov$description[stringr::str_detect(geocov$description, "Stinson Mountain")] <- 
    "Stinson Mountain"
  geocov$description[stringr::str_detect(geocov$description, "Russell Pond")] <- 
    "Russell Pond"
  geocov <- dplyr::rename(geocov, site = description)
  
  flat$site[stringr::str_detect(flat$site, "Hubbard Brook")] <- 
    "Hubbard Brook"
  flat$site[stringr::str_detect(flat$site, "Moosilauke")] <- 
    "Mount Moosilauke"
  flat$site[stringr::str_detect(flat$site, "Stinson")] <- 
    "Stinson Mountain"
  flat$site[stringr::str_detect(flat$site, "Russell")] <- 
    "Russell Pond"
  
  flat <- dplyr::left_join(flat, geocov, by = "site")
  
  # Add columns for the taxon table -------------------------------------------
  
  flat$taxon_id <- flat %>% dplyr::group_by(taxon_name) %>% dplyr::group_indices()
  
  # While not required, resolving taxonomic entities to an authority system 
  # improves the discoverability and interoperability of the ecocomDP dataset. 
  # We can resolve taxa by sending names through taxonomyCleanr for direct 
  # matches against the Integrated Taxonomic Information System 
  # (ITIS; https://www.itis.gov/).
  
  taxa_resolved <- taxonomyCleanr::resolve_comm_taxa(
    x = unique(flat$taxon_name),
    data.sources = 3)
  
  taxa_resolved <- taxa_resolved %>%
    dplyr::select(taxa, rank, authority, authority_id) %>%
    dplyr::rename(taxon_rank = rank,
           taxon_name = taxa,
           authority_system = authority,
           authority_taxon_id = authority_id)
  
  flat <- dplyr::left_join(flat, taxa_resolved, by = "taxon_name")
  
  # Add columns for the dataset_summary table ---------------------------------
  
  # Add arbitrary month and day for calculating temporal metrics
  
  dates <- flat$datetime %>% stats::na.omit() %>% sort()
  dates <- lubridate::ymd(paste0(dates, "-01-01"))
  
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
      west = min(geocov$longitude), 
      east = max(geocov$longitude), 
      north = max(geocov$latitude), 
      south = min(geocov$latitude))
  
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
    location_name = c("site"), 
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
    variable_name = c("comment"))
  
  # Create the variable_mapping table. This is optional but highly recommended 
  # as it provides unambiguous definitions to variables and facilitates 
  # integration with other ecocomDP datasets.
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary)
  
  i <- variable_mapping$variable_name == 'count'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/individualCount'
  variable_mapping$mapped_label[i] <- 'individualCount'
  
  i <- variable_mapping$variable_name == 'comment'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/organismRemarks'
  variable_mapping$mapped_label[i] <- 'organismRemarks'
  
  # Write tables to file
  
  ecocomDP::write_tables(
    path = path, 
    observation = observation, 
    location = location,
    taxon = taxon,
    dataset_summary = dataset_summary, 
    observation_ancillary = observation_ancillary,
    variable_mapping = variable_mapping)
  
  # Validate tables -----------------------------------------------------------
  
  # Validation checks ensure the derived set of tables comply with the ecocomDP
  # model. Any issues at this point 
  # should be addressed in the lines of code above, the tables rewritten, and 
  # another round of validation, to be certain the fix worked.
  
  issues <- ecocomDP::validate_data(path = path)
  
  # Create metadata -----------------------------------------------------------
  
  # Convert "dataset level keywords" listed in the source to "dataset level 
  # annotations" in the derived.
  
  dataset_annotations <- c(
    `ecological community` = "http://purl.obolibrary.org/obo/PCO_0000002")
  
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
      "A function for converting knb-lter-hbr.81 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
  
}








# Parse EML geographic goverage to data frame
#
# @param eml (xml_document, xml_node) EML metadata
# @param xpath (character) Xpath to coverage node containing geographic information
# @param avg (logical) Whether to average N/S, E/W, and elevation components in to single values
#
# @return (data.frame) A data frame of geographic coverage
#
geocov_2_dataframe <- function(eml, xpath, avg = FALSE) {
  geocov <- xml2::xml_find_all(eml, xpath)
  r <- lapply(
    geocov, 
    function(node) {
      # Parse
      desc <- xml2::xml_text(xml2::xml_find_all(node, ".//geographicDescription"))
      west <- xml2::xml_double(xml2::xml_find_all(node, ".//westBoundingCoordinate"))
      east <- xml2::xml_double(xml2::xml_find_all(node, ".//eastBoundingCoordinate"))
      north <- xml2::xml_double(xml2::xml_find_all(node, ".//northBoundingCoordinate"))
      south <- xml2::xml_double(xml2::xml_find_all(node, ".//southBoundingCoordinate"))
      # altmin <- xml2::xml_double(xml2::xml_find_all(node, ".//altitudeMinimum"))
      # altmax <- xml2::xml_double(xml2::xml_find_all(node, ".//altitudeMaximum")
      # Return as data frame
      if (isTRUE(avg)) {
        r <- data.frame(
          description = desc,
          latitude = mean(c(north, south), na.rm = TRUE),
          longitude = mean(c(west, east), na.rm = TRUE),
          # elevation = mean(c(altmin, altmax), na.rm = TRUE),
          stringsAsFactors = FALSE)
      } else {
        r <- data.frame(
          description = desc,
          north = north,
          east = east,
          south = south,
          west = west,
          # elev_max = altmax,
          # elev_min = altmin,
          stringsAsFactors = FALSE)
      }
      return(r)
    })
  r <- data.table::rbindlist(r)
  return(r)
}
