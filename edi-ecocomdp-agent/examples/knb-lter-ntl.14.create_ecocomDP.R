#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-ntl.14" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.284" (also archived in EDI)
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
#             "edi.284" whenever new data are added to the source 
#             "knb-lter-ntl.14". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-ntl.14". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-ntl.14":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-ntl&identifier=14
# Landing page to derived dataset "edi.284":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=284
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


create_ecocomDP <-  function(path,
                             source_id,
                             derived_id,
                             url = NULL) {
  

# Read source dataset -----------------------------------------------------

  eml <- EDIutils::api_read_metadata(source_id)
  data <- EDIutils::read_tables(
    eml = eml, 
    strip.white = TRUE,
    na.strings = "",
    convert.missing.value = TRUE, 
    add.units = TRUE)
  

# Flatten source dataset --------------------------------------------------

  # One table, no joining
  
  wide <- data$ntl14_v9.csv
  
  wide <- wide %>% dplyr::rename(
    value.avg_ind = avg_ind,
    unit.avg_ind = unit_avg_ind,
    value.stdev_ind = stdev_ind,
    unit.stdev_ind = unit_stdev_ind,
    value.avg_ind_per_m3 = avg_ind_per_m3,
    unit.avg_ind_per_m3 = unit_avg_ind_per_m3,
    value.avg_ind_per_m2 = avg_ind_per_m2,
    unit.avg_ind_per_m2 = unit_avg_ind_per_m2,
    value.stdev_ind_per_m3 = stdev_ind_per_m3,
    unit.stdev_ind_per_m3 = unit_stdev_ind_per_m3,
    value.stdev_ind_per_m2 = stdev_ind_per_m2,
    unit.stdev_ind_per_m2 = unit_stdev_ind_per_m2)
  
  
  flat <- tidyr::pivot_longer(
    wide,
    cols = matches(c("avg_ind", "stdev_ind")), 
    names_to = c(".value", "variable_name"), 
    names_sep = '\\.')
  
  
  # Sorting and arranging rows by sample date and location 
  
  flat <- flat %>% dplyr::arrange(year4, lakeid, sta)
  

# Add columns for observation table ---------------------------------------

  # Each row of the flattened source dataset represents an observation of taxa 
  # abundance and should have a unique ID for reference
  
  flat$observation_id <- seq(nrow(flat))
  
  # Observations are made in transects, which are nested in sites. A subset of samples are divided into  Unique 
  # combinations of these form a location
  
  flat$location_id <- flat %>% group_by(lakeid) %>% group_indices()
  
  # Each combination of location and date form a sampling event
  
  flat$event_id <- flat %>% group_by(year4, lakeid) %>% group_indices()
  
  
  # Add columns for the location table ----------------------------------------
  
  geocov <- xml2::xml_find_all(eml, ".//geographicCoverage")
  sites <- xml2::xml_text(
    xml2::xml_find_all(geocov,'.//geographicDescription'))
  north <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/northBoundingCoordinate'))
  east <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/eastBoundingCoordinate'))
  south <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/southBoundingCoordinate'))
  west <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/westBoundingCoordinate'))
  
  # Create geo table and join with flat table on SITE 
  # EML contained a coordinate for each site. Site code in EML matches the 
  # site code in the SITE column
  site_full_names <- c(
    'Allequash Lake',
    'Big Muskellunge Lake',
    'Crystal Bog',
    'Crystal Lake',
    'Sparkling Lake',
    'Trout Bog',
    'Trout Lake'
  )
  
  site_code_list <- c('AL', 
                      'BM', 
                      'CB', 
                      'CR', 
                      'SP', 
                      'TB', 
                      'TR')
  
  sites <- stringr::str_replace_all(sites, site_full_names, site_code_list)
  
  geo <- dplyr::tibble(
    "lakeid" = paste0(substr(sites, 0,2)),
    "north" = north,
    "south" = south,
    "east" = east,
    "west" = west
  ) %>% dplyr::mutate(
    latitude = rowMeans(select(., c('north', 'south'))),
    longitude = rowMeans(select(., c('east', 'west'))),
  ) %>% select(
    -c(north, south, east, west)
  )
  
  flat <- dplyr::left_join(flat, geo, by = "lakeid")
  
  # Add columns for the taxon table -------------------------------------------
  
  flat <- flat %>% 
    dplyr::mutate(taxon_name = taxon) %>% 
    dplyr::select(-taxon)
  
  # Taxonomic entities of this dataset are comprised of unique genus and 
  # species pairs
  
  flat$taxon_id <- flat %>% group_by(taxon_name) %>% group_indices()
  
  taxa_resolved <- taxonomyCleanr::resolve_sci_taxa(
    x = unique(flat$taxon_name),
    data.sources = c(3, 11))
  
  taxa_resolved <- taxa_resolved %>%
    dplyr::select(taxa, rank, authority, authority_id) %>%
    dplyr::rename(
      taxon_rank = rank,
      taxon_name = taxa,
      authority_system = authority,
      authority_taxon_id = authority_id)
  
  flat <- dplyr::left_join(flat, taxa_resolved, by = "taxon_name")

  # Add columns for the dataset_summary table ---------------------------------
  
  dates <- flat$year4 %>% na.omit() %>% sort()
  dates <- paste0(dates, "-01-01")
  dates <- lubridate::ymd(dates)
  
  flat$package_id <- derived_id
  flat$original_package_id <- paste0(source_id)
  flat$length_of_survey_years <- ecocomDP::calc_length_of_survey_years(dates)
  flat$number_of_years_sampled <- ecocomDP::calc_number_of_years_sampled(dates)
  flat$std_dev_interval_betw_years <- 
    ecocomDP::calc_std_dev_interval_betw_years(dates)
  flat$max_num_taxa <- length(unique(flat$taxon_name))
  flat$geo_extent_bounding_box_m2 <- 
    ecocomDP::calc_geo_extent_bounding_box_m2(min(flat$longitude, na.rm = TRUE),
                                              max(flat$longitude, na.rm = TRUE),
                                              max(flat$latitude, na.rm = TRUE),
                                              min(flat$latitude, na.rm = TRUE))
  
  # Odds and ends -------------------------------------------------------------
  
  # Rename source columns with an ecocomDP equivalent and 
  # remove columns of redundant information.
  
  flat <- flat %>% 
    dplyr::rename(datetime = year4)
  
  flat$author <- NA_character_
  
  
  # Parse flat into ecocomDP tables -------------------------------------------
  
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
    location_name = c("lakeid"), 
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
  
  
  # Create the ancillary ecocomDP tables.
  
  observation_ancillary <- ecocomDP::create_observation_ancillary(
    L0_flat = flat,
    observation_id = "observation_id", 
    variable_name = c("depth", "sta", "nreps"),
    unit = c("unit_depth", "unit_nreps"))
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary)
  
  i <- variable_mapping$variable_name == 'depth'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/verbatimDepth'
  variable_mapping$mapped_label[i] <- 'verbatimDepth'
  
  i <- variable_mapping$variable_name == 'rep'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002989'
  variable_mapping$mapped_label[i] <- 'replicate identifier'
  
  i <- variable_mapping$variable_name == 'nreps'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002764'
  variable_mapping$mapped_label[i] <- 'number of samples taken'
  
  i <- variable_mapping$variable_name == 'avg_ind_per_m2'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001168'
  variable_mapping$mapped_label[i] <- 'Areal Density Measurement Type'
  
  i <- variable_mapping$variable_name == 'avg_ind_per_m3'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001199'
  variable_mapping$mapped_label[i] <- 'Volumetric Density Measurement Type'
  
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
  
  issues <- ecocomDP::validate_data(path = path)
  
  # Create metadata -----------------------------------------------------------
  
  # Convert "dataset level keywords" listed in the source to "dataset level 
  # annotations" in the derived.
  
  dataset_annotations <- c(
    `species abundance` = 
      "http://purl.dataone.org/odo/ECSO_00001688",
    Population = 
      "http://purl.dataone.org/odo/ECSO_00000311",
    `species` =
      'http://purl.dataone.org/odo/ECSO_00000313',
    `lake` = 
      "http://purl.obolibrary.org/obo/ENVO_00000020"
  )
  
  # Add contact information for the author of this script and dataset
  
  additional_contact <- data.frame(
    givenName = 'Kyle',
    surName = 'Zollo-Venecek',
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
      "A function for converting knb-lter-ntl.14 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
  
}




