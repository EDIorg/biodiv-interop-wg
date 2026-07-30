#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-sev.23" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.334" (also archived in EDI)
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
#             "edi.334" whenever new data are added to the source 
#             "knb-lter-sev.23". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-sev.23". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-sev.23":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-sev&identifier=23
# Landing page to derived dataset "edi.334":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=334
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
    add.units = TRUE)[[1]]
  
  # Metadata defines Sample Unit as "Individual rabbit"
  
  data$value.individual_rabbit <- 1
  data$unit.individual_rabbit <- "count"
  
  # Flatten source dataset --------------------------------------------------

  flat <- data %>% 
    tidyr::pivot_longer(cols = matches(c("individual_rabbit")),
                        names_to = c(".value", "variable_name"),
                        names_sep = "\\.")
  
  # Sorting and arranging rows by year and location 
  
  flat <- flat %>% dplyr::arrange(Year, as.numeric(month), as.numeric(day), leg)
  
  # Add columns for the observation table -----------------------------------
  
  flat$observation_id <- seq(nrow(flat))
  
  
  # Location is divided into four legs
  
  flat$location_id <- flat %>% group_by(leg) %>% group_indices()
  
  # Each sample value in the table represents a different event
  # For events spanning multiple days, the sample number adds a decimal value
  
  flat$event_id <- flat %>% group_by(Year, month) %>% group_indices()
  
  # Add columns for the location table ----------------------------------------
  
  geocov <- xml2::xml_find_all(eml, ".//geographicCoverage")
  sites <- xml2::xml_text(
    xml2::xml_find_all(geocov, './/geographicDescription'))
  north <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/northBoundingCoordinate'))
  east <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/eastBoundingCoordinate'))
  south <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/southBoundingCoordinate'))
  west <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/westBoundingCoordinate'))
  
  # Create longitude and latitude from bounding box of geocov
  
  flat <- flat %>% dplyr::mutate(
    latitude = mean(c(north, south)),
    longitude = mean(c(east, west)))
  
  # Add columns for the taxon table -------------------------------------------
  
  flat <- flat %>%
    rename(taxon_name = species)
  
  flat$taxon_id <- flat %>% group_by(taxon_name) %>% group_indices()
  
  # While not required, resolving taxonomic entities to an authority system 
  # improves the discoverability and interoperability of the ecocomDP dataset. 
  
  taxa_resolved <- taxonomyCleanr::resolve_sci_taxa(
    x = unique(flat$taxon_name),
    data.sources = c(3))
  
  taxa_resolved <- taxa_resolved %>%
    dplyr::select(taxa, rank, authority, authority_id) %>%
    dplyr::rename(
      taxon_rank = rank,
      taxon_name = taxa,
      authority_system = authority,
      authority_taxon_id = authority_id)
  
  flat <- dplyr::left_join(flat, taxa_resolved, by = "taxon_name")
  
  # Add columns for the dataset_summary table ---------------------------------
  
  flat$datetime <- lubridate::ymd(
    paste0(flat$Year, '-', flat$month, '-', flat$day))
  
  dates <- flat$datetime %>% na.omit() %>% sort()
  
  flat$package_id <- derived_id
  flat$original_package_id <- source_id
  flat$length_of_survey_years <- ecocomDP::calc_length_of_survey_years(dates)
  flat$number_of_years_sampled <- ecocomDP::calc_number_of_years_sampled(dates)
  flat$std_dev_interval_betw_years <- 
    ecocomDP::calc_std_dev_interval_betw_years(dates)
  flat$max_num_taxa <- length(unique(flat$taxon_name))
  flat$geo_extent_bounding_box_m2 <- 
    ecocomDP::calc_geo_extent_bounding_box_m2(west, east, north, south)
  
  # Odds and ends -------------------------------------------------------------
  
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
    location_name = c("leg"),
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
    variable_name = c("side", "mileage", "distance"))
  
  # Create the variable_mapping table.
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary)
  
  i <- variable_mapping$variable_name == 'individual_rabbit'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/individualCount'
  variable_mapping$mapped_label[i] <- 'individualCount'
  
  i <- variable_mapping$variable_name == 'mileage'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00003023'
  variable_mapping$mapped_label[i] <- 'location along transect or plot'
  
  i <- variable_mapping$variable_name == 'distance'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001710'
  variable_mapping$mapped_label[i] <- 'distance'
  
  # Write tables to file
  
  ecocomDP::write_tables(
    path = path, 
    observation = observation, 
    location = location,
    taxon = taxon,
    observation_ancillary = observation_ancillary,
    dataset_summary = dataset_summary, 
    variable_mapping = variable_mapping)
  
  # Validate tables -----------------------------------------------------------
  
  issues <- ecocomDP::validate_data(path = path)
  
  # Convert "dataset level keywords" listed in the source to "dataset level 
  # annotations" in the derived.
  
  # Create metadata ---------------------------------------------------------
  
  dataset_annotations <- c(
    `Population` =
      "http://purl.dataone.org/odo/ECSO_00000311",
    `ecological community` =
      "http://purl.obolibrary.org/obo/NCBITaxon_3193",
    `species abundance` = 
      "http://purl.dataone.org/odo/ECSO_00001688",
    `desert` = 
      "http://purl.obolibrary.org/obo/ENVO_01001357",
    `grassland ecosystem` =
      "http://purl.obolibrary.org/obo/ENVO_01001206",
    `Mammalia` = 
      "http://purl.obolibrary.org/obo/NCBITaxon_40674")
  
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
      "A function for converting knb-lter-sev.23 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
  
    
}