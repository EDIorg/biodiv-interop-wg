#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-ntl.356" (archived in the EDI
# Data Repository) to ecocomDP dataset "ntl.346" (also archived in EDI)
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
#             "ntl.346" whenever new data are added to the source 
#             "knb-lter-ntl.356". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-ntl.356". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-ntl.356":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-ntl&identifier=356
# Landing page to derived dataset "ntl.346":
# https://portal.edirepository.org/nis/mapbrowse?scope=ntl&identifier=346
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
  
  fish <- data$WIfishAbundance.csv
  taxa <- data$taxon_information.csv
  location <- data$sampling_location.csv
  

# Flatten source dataset --------------------------------------------------

  # fish table jois with taxa by taxon_id 
  
  wide <- dplyr::left_join(fish, taxa, by = "taxon_id")
  
  # location table joins with fish table by WBIC (lake id)
  
  wide <- wide %>% dplyr::left_join(location, by = "WBIC")
  
  wide <- wide %>% 
    dplyr::rename(value_CPUE = CPUE,
                  value_LOGCPUE = LOGCPUE)
  
  flat <- tidyr::pivot_longer(
    wide,
    cols = matches("CPUE"), 
    names_to = c(".value", "variable_name"), 
    names_sep = '\\_')
  
  # Sorting and arranging rows by year and location 
  
  flat <- flat %>% dplyr::arrange(YEAR, Waterbody_Name)
  
  # Add columns for the observation table -----------------------------------
  
  flat$observation_id <- seq(nrow(flat))
  
  # Location is divided by the different Lakes
  
  flat$location_id <- flat %>% group_by(Waterbody_Name) %>% group_indices()
  
  # Surveys occurred biweekly, the column Collection_Date delineates events
  
  flat$event_id <- flat %>% group_by(YEAR) %>% group_indices()
  

# Add columns for location table ------------------------------------------

  # This information included in L0 tables

# Add columns for the taxon table -----------------------------------------

  # This information included in L0 tables
  
  # Add columns for the dataset_summary table ---------------------------------
  
  dates <- flat$YEAR %>% na.omit() %>% sort()
  dates <- lubridate::ymd(paste0(dates, "-01-01"))
  
  flat$package_id <- derived_id
  flat$original_package_id <- source_id
  flat$length_of_survey_years <- ecocomDP::calc_length_of_survey_years(dates)
  flat$number_of_years_sampled <- ecocomDP::calc_number_of_years_sampled(dates)
  flat$std_dev_interval_betw_years <- 
    ecocomDP::calc_std_dev_interval_betw_years(dates)
  flat$max_num_taxa <- length(unique(flat$taxon_name))
  flat$geo_extent_bounding_box_m2 <- 
    ecocomDP::calc_geo_extent_bounding_box_m2(
      min(flat$Longitude), max(flat$Longitude), max(flat$Latitude), min(flat$Latitude))
  
  # Odds and ends -------------------------------------------------------------
  
  # Rename source columns with an ecocomDP equivalent
  
  flat <- flat %>% 
    dplyr::rename(datetime = YEAR) 
  
  flat$author <- NA_character_
  
  
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
    location_name = c("Waterbody_Name"),
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
  
  # Create the ancillary ecocomDP tables. These are optional, but should be 
  # included if possible.
  
  observation_ancillary <- ecocomDP::create_observation_ancillary(
    L0_flat = flat,
    observation_id = "observation_id",
    variable_name = c("GEARNAME", "N", "WBIC"),
    unit = c("unit_N"))
  
  # Create the variable_mapping table.
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary,
    location_ancillary = location_ancillary)
  
  i <- variable_mapping$variable_name == 'GEARNAME'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001591'
  variable_mapping$mapped_label[i] <- 'type of trap'
  
  i <- variable_mapping$variable_name == 'Waterbody_Name'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/waterBody'
  variable_mapping$mapped_label[i] <- 'waterBody'  
  
  # Write tables to file
  
  ecocomDP::write_tables(
    path = path, 
    observation = observation, 
    location = location,
    taxon = taxon,
    observation_ancillary = observation_ancillary,
    location_ancillary = location_ancillary,
    dataset_summary = dataset_summary, 
    variable_mapping = variable_mapping)
  
  # Validate tables -----------------------------------------------------------
  
  issues <- ecocomDP::validate_data(path = path)
  
  # Convert "dataset level keywords" listed in the source to "dataset level 
  # annotations" in the derived.
  
  # Create metadata ---------------------------------------------------------
  
  dataset_annotations <- c(
    `ecological community` = 
      "http://purl.obolibrary.org/obo/NCBITaxon_3193",
    `Population` = 
      "http://purl.dataone.org/odo/ECSO_00000311",
    `lake` = 
      "http://purl.obolibrary.org/obo/ENVO_00000020",
    `species abundance` = 
      "http://purl.dataone.org/odo/ECSO_00001688")
  
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
      "A function for converting knb-lter-ntl.356 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
  
}




