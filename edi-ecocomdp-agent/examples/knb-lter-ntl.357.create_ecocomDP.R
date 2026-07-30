#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-ntl.357" (archived in the EDI
# Data Repository) to ecocomDP dataset "knb-lter-ntl.345" (also archived in EDI)
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
#             "knb-lter-ntl.345" whenever new data are added to the source 
#             "knb-lter-ntl.357". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-ntl.357". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-ntl.357":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-ntl&identifier=357
# Landing page to derived dataset "knb-lter-ntl.345":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-ntl&identifier=345
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
  # Read source dataset -------------------------------------------------
  
  eml <- EDIutils::api_read_metadata(source_id)
  data <- EDIutils::read_tables(
    eml = eml, 
    strip.white = TRUE,
    na.strings = "",
    convert.missing.value = TRUE, 
    add.units = TRUE)
  
  # Dataset contains three tables
  fish <- data$`WIfishsize.csv`
  taxa <- data$`taxon_information.csv`
  geo <- data$`sampling_location.csv`
  
  # Join and flatten the source dataset ---------------------------------------
  
  wide <- dplyr::left_join(fish, taxa, by = "taxon_id") %>% 
    dplyr::left_join(geo, by = "WBIC")
  
  # Convert wide format to "flat" format. This is the wide form but gathered on 
  # core observation variables.
  
  wide <- wide %>% dplyr::rename(value_TL = TL)
  flat <- tidyr::pivot_longer(
    wide,
    cols = matches("TL"), 
    names_to = c(".value", "variable_name"), 
    names_sep = '\\_')
  
  # Sorting and arranging rows by sample date and location 
  
  flat <- flat %>% dplyr::arrange(YEAR, WBIC)

# Add columns for the observation table -----------------------------------

  
  # Each row of the flattened source dataset represents an observation of taxa 
  # abundance and should have a unique ID for reference
  
  flat$observation_id <- seq(nrow(flat))
  
  # Observations are made in transects, which are nested in sites. A subset of samples are divided into  Unique 
  # combinations of these form a location
  
  flat$location_id <- flat %>% group_by(WBIC) %>% group_indices()
  
  # Each combination of location and date form a sampling event
  
  flat$event_id <- flat %>% group_by(YEAR, WBIC) %>% group_indices()
  

  # Add columns for the taxon table -------------------------------------------
  
  # Taxonomic entities of this dataset are comprised of unique genus and 
  # species pairs
  
  flat$taxon_id <- flat %>% group_by(taxon_name) %>% group_indices()
  
  # Since all taxonomic entity information is already resolved to ITIS,
  # simply changing format of information is sufficient
  
  flat <- flat %>% mutate(
    taxon_rank = ifelse(taxon_rank == 'species', 'Species', taxon_rank),
    authority_system = ifelse(authority_system == 'https://www.itis.gov/', 'ITIS', authority_system)
  )
  
  # Add columns for the dataset_summary table ---------------------------------
  
  dates <- flat$YEAR %>% na.omit() %>% sort()
  dates <- paste0(dates, "-01-01")
  dates <- lubridate::ymd(dates)
  
  flat$package_id <- derived_id
  flat$original_package_id <- source_id
  flat$length_of_survey_years <- ecocomDP::calc_length_of_survey_years(dates)
  flat$number_of_years_sampled <- ecocomDP::calc_number_of_years_sampled(dates)
  flat$std_dev_interval_betw_years <- 
    ecocomDP::calc_std_dev_interval_betw_years(dates)
  flat$max_num_taxa <- length(unique(flat$taxon_name))
  flat$geo_extent_bounding_box_m2 <- 
    ecocomDP::calc_geo_extent_bounding_box_m2(min(flat$Longitude, na.rm = TRUE),
                                              max(flat$Longitude, na.rm = TRUE),
                                              max(flat$Latitude, na.rm = TRUE),
                                              min(flat$Latitude, na.rm = TRUE))
  
  # Odds and ends -------------------------------------------------------------
  
  # Rename source columns with an ecocomDP equivalent and 
  # remove columns of redundant information.
  
  flat <- flat %>% 
    dplyr::rename(datetime = YEAR) %>% 
    dplyr::select(-unit_YEAR)
  
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
    location_name = c("WBIC"), 
    latitude = "Latitude", 
    longitude = "Longitude")
  
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
    variable_name = c("GEARNAME"))
  
  location_ancillary <- ecocomDP::create_location_ancillary(
    L0_flat = flat,
    location_id = "location_id",
    variable_name = "Waterbody Name")

  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary,
    location_ancillary = location_ancillary)
  
  i <- variable_mapping$variable_name == 'TL'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/measurementType'
  variable_mapping$mapped_label[i] <- 'measurementType'
  
  i <- variable_mapping$variable_name == 'GEARNAME'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002527'
  variable_mapping$mapped_label[i] <- 'data collection equipment'
  
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
  
  issues <- ecocomDP::validate_data(path = path)
  
  # Create metadata -----------------------------------------------------------
  
  # Convert "dataset level keywords" listed in the source to "dataset level 
  # annotations" in the derived.
  
  dataset_annotations <- c(
    `community` = 
      "http://purl.dataone.org/odo/ECSO_00000310",
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
      "A function for converting knb-lter-ntl.357 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
}




