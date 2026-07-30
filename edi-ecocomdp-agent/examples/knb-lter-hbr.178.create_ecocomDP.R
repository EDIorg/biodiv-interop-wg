#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-hbr.178" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.348" (also archived in EDI)
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
#             "edi.348" whenever new data are added to the source 
#             "knb-lter-hbr.178". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-hbr.178". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-hbr.178":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-hbr&identifier=178
# Landing page to derived dataset "edi.348":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=348
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
  
  # Create "count" variable, value, and unit columns. Each observation is recorded by species code
  
  data$value <- 1
  
  data$variable_name <- "count"
  
  data$unit <- "number"
  
  # Sorting and arranging rows by year and location
  
  flat <- data %>% dplyr::arrange(Date, Time, Plot)
  
  # Add columns for the observation table -----------------------------------
  
  flat$observation_id <- seq(nrow(flat))
  
  # Location is divided by the different site and treatments within them
  
  flat$location_id <- flat %>% group_by(Plot) %>% group_indices()
  
  # Surveys are defined by the SAMPLE column
  
  flat$event_id <- flat %>% group_by(lubridate::year(Date)) %>% group_indices()
  
  # Add columns for the location table ----------------------------------------
  
  geocov <- xml2::xml_find_all(eml, ".//geographicCoverage")
  sites <- xml2::xml_text(
    xml2::xml_find_all(geocov, './/geographicDescription'))
  north <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/northBoundingCoordinate'))[[1]]
  east <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/eastBoundingCoordinate'))[[1]]
  south <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/southBoundingCoordinate'))[[1]]
  west <- xml2::xml_double(
    xml2::xml_find_all(geocov, './/westBoundingCoordinate'))[[1]]
  
  flat <- flat %>% dplyr::mutate(
    latitude = mean(c(north, south)),
    longitude = mean(c(east, west)))
  
  
  # Add columns for the taxon table -------------------------------------------
  
  flat <- flat %>% dplyr::rename(taxon_name = Species)
  
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
  
  dates <- flat$Date %>% na.omit() %>% sort()
  
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
  
  # Rename source columns with an ecocomDP equivalent
  
  flat <- flat %>% 
    dplyr::rename(datetime = Date) 
  
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
    location_name = c("Plot"),
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
    variable_name = c("Time", "Replicate", "Observer", "Sky", "Wind",
                      "Bird.Number", "Period", "Minute", "Sex", "Detection.Method",
                      "Distance", "New.Record", "Counter.sing", "Comments"))
  
  # Create the variable_mapping table.
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary)
  
  i <- variable_mapping$variable_name == 'count'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/individualCount'
  variable_mapping$mapped_label[i] <- 'individualCount'
  
  i <- variable_mapping$variable_name == 'Observer'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/recordedBy'
  variable_mapping$mapped_label[i] <- 'recordedBy'  
  
  i <- variable_mapping$variable_name == 'Time'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventTime'
  variable_mapping$mapped_label[i] <- 'eventTime' 
  
  i <- variable_mapping$variable_name == 'Replicate'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002989'
  variable_mapping$mapped_label[i] <- 'replicate identifier'
  
  i <- variable_mapping$variable_name == 'Period'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002953'
  variable_mapping$mapped_label[i] <- 'sample measurement period'
  
  i <- variable_mapping$variable_name == 'Minute'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002238'
  variable_mapping$mapped_label[i] <- 'minutes elapsed'
  
  i <- variable_mapping$variable_name == 'Sex'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/sex'
  variable_mapping$mapped_label[i] <- 'sex'
  
  i <- variable_mapping$variable_name == 'Detection.Method'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/samplingProtocol'
  variable_mapping$mapped_label[i] <- 'samplingProtocol'
  
  i <- variable_mapping$variable_name == 'Distance'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001710'
  variable_mapping$mapped_label[i] <- 'water sample volume'
  
  i <- variable_mapping$variable_name == 'Comments'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventRemarks'
  variable_mapping$mapped_label[i] <- 'eventRemarks'
  
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
    `Metazoa` = 
      "http://purl.obolibrary.org/obo/NCBITaxon_33208",
    `Aves` = 
      "http://purl.obolibrary.org/obo/NCBITaxon_8782",
    `ecosystem` = 
      "http://purl.obolibrary.org/obo/ENVO_01001110",
    `elevation` = 
      "http://purl.obolibrary.org/obo/PATO_0001687",
    `forested area` = 
      "http://purl.obolibrary.org/obo/ENVO_00000111")
  
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
      "A function for converting knb-lter-hbr.178 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
  
}