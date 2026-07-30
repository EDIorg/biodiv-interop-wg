#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-bnz.502" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.264" (also archived in EDI)
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
#             "edi.264" whenever new data are added to the source 
#             "knb-lter-bnz.502". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-bnz.502". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-bnz.502":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-bnz&identifier=502
# Landing page to derived dataset "edi.264":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=264
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
  
  # One table, no joining  
  
  # Use regex strings to access data tables
  # Tables have auto-generated hash associated with revisions
  
  data_names <- as.list(names(data))
  
  data_string <- stringr::str_extract(
    data_names, "(502_EML_AK_DryPEHR_BiomassBySpecies_)(.+)")
  
  data_string <- data_string[!is.na(data_string)]
  
  wide <- data[[data_string]]
  
  # Convert wide format to "flat" format. This is the wide form but gathered on 
  # core observation variables.
  
  wide <- wide %>% dplyr::rename(
    value_avghits = avghits,
    value_biomass = biomass)
  
  flat <- tidyr::pivot_longer(
    wide,
    cols = matches(c("avghits", "biomass")), 
    names_to = c(".value", "variable_name"), 
    names_sep = '\\_')
  
  flat <- flat %>% dplyr::arrange(year, plot)
  
  # Add columns for the observation table -----------------------------------
  
  # Each row of the flattened source dataset represents an observation of taxa 
  # abundance and should have a unique ID for reference
  
  flat$observation_id <- seq(nrow(flat))
  
  # Observations are made at the plot level; each distinct plot represents
  # one of three treatments: drying, warming, or drying and warming
  
  flat$location_id <- flat %>% group_by(block, fence, plot) %>% group_indices()
  
  # Each combination of location and date form a sampling event
  
  flat$event_id <- flat %>% group_by(year, block, fence, plot) %>% group_indices()
  
  
  # Add columns for the location table --------------------------------------
  
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
  
  # Two sets of coordinates are presented. One is from the geographicCoverage
  # node in the EML node, one is from the sampling extent. We are using the 
  # mean of the two coordinates
  
  flat$latitude <- mean(c(north, south))
  flat$longitude <- mean(c(east, west))
  
  
  # Add columns for the taxon table -------------------------------------------
  
  flat <- flat %>% 
    dplyr::mutate(taxon_name = species) %>% 
    dplyr::select(-species)
  
  # NOTE: species (which becomes taxon_name) is currently composed of codes
  # Request that IM update submitted
  
  flat$taxon_id <- flat %>% group_by(taxon_name) %>% group_indices()
  
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
  
  dates <- flat$year %>% na.omit() %>% sort()
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
    ecocomDP::calc_geo_extent_bounding_box_m2(min(flat$longitude, na.rm = TRUE),
                                              max(flat$longitude, na.rm = TRUE),
                                              max(flat$latitude, na.rm = TRUE),
                                              min(flat$latitude, na.rm = TRUE))
  
  # Odds and ends -------------------------------------------------------------
  
  # Rename source columns with an ecocomDP equivalent and 
  # remove columns of redundant information.
  
  flat <- flat %>% 
    dplyr::rename(datetime = year) %>% 
    dplyr::select(-unit_year)
  
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
    location_name = c("block", "fence", "plot"), 
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
  
  location_ancillary <- ecocomDP::create_location_ancillary(
    L0_flat = flat,
    location_id = "location_id", 
    variable_name = c("dry"))
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    location_ancillary = location_ancillary)
  
  i <- variable_mapping$variable_name == 'biomass'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/organismQuantity'
  variable_mapping$mapped_label[i] <- 'organismQuantity'
  
  i <- variable_mapping$variable_name == 'avghits'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/organismQuantity'
  variable_mapping$mapped_label[i] <- 'organismQuantity'
  
  i <- variable_mapping$variable_name == 'fence'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002558'
  variable_mapping$mapped_label[i] <- 'fence identifier'
  
  i <- variable_mapping$variable_name == 'block'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002601'
  variable_mapping$mapped_label[i] <- 'block identifier'
  
  i <- variable_mapping$variable_name == 'plot'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002432'
  variable_mapping$mapped_label[i] <- 'plot identifier'
  
  i <- variable_mapping$variable_name == 'dry'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002426'
  variable_mapping$mapped_label[i] <- 'treatment measurement type'
  
  
  # Write tables to file
  
  ecocomDP::write_tables(
    path = path, 
    observation = observation, 
    location = location,
    taxon = taxon,
    dataset_summary = dataset_summary, 
    location_ancillary = location_ancillary,
    variable_mapping = variable_mapping)
  
  # Validate tables -----------------------------------------------------------
  
  issues <- ecocomDP::validate_data(path = path)
  
  # Create metadata -----------------------------------------------------------
  
  # Convert "dataset level keywords" listed in the source to "dataset level 
  # annotations" in the derived. The predicate "is about" is used, which 
  # results in an annotation that reads "This dataset is about 'species 
  # abundance'", "This dataset is about 'Population', etc.
  
  dataset_annotations <- c(
    `Manipulative experiment` = 
      "http://purl.dataone.org/odo/ECSO_00000506",
    `Biomass` =
      "http://purl.dataone.org/odo/ECSO_00001114",
    `warming treatment` =
      "http://purl.dataone.org/odo/ECSO_00002890",
    `permafrost` = 
      "http://purl.obolibrary.org/obo/ENVO_00000134",
    `tundra biome` = 
      "http://purl.obolibrary.org/obo/ENVO_01000180",
    `fence` = 
      "http://purl.obolibrary.org/obo/ENVO_01000468",
    `embryophyta` =
      "http://purl.obolibrary.org/obo/NCBITaxon_3193",
    `permafrost drying treatment` =
      "http://purl.dataone.org/odo/ECSO_00002441",
    `permafrost active layer` = 
      "http://www.purl.dataone.org/odo/ECSO_00010089",
    `Active Layer Thickness MOV` =
      "http://purl.dataone.org/odo/ECSO_00000068",
    `Community` = 
      "http://purl.dataone.org/odo/ECSO_00000310")
  
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
      "A function for converting knb-lter-bnz.502 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
}
