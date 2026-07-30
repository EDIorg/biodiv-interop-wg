#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-hbr.82" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.349" (also archived in EDI)
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
#             "edi.349" whenever new data are added to the source 
#             "knb-lter-hbr.82". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-hbr.82". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-hbr.82":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-hbr&identifier=82
# Landing page to derived dataset "edi.349":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=349
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
  
  hb <- tableRE(data, "(lepidoptera_HB_)(.+)")
  wmnf <- data$lepidoptera_WMNFsites.csv %>% 
    dplyr::rename(TreeSpecies = TreeSpeceis)
  

# Join and flatten source dataset -----------------------------------------

  # match types
  
  hb$NumberIndividuals <- as.character(hb$NumberIndividuals)
  hb$length <- as.character(hb$length)
  
  wide <- dplyr::bind_rows(hb, wmnf)
  
  core_variables <- c("NumberIndividuals", "length", "biomass")
  
  wide <- wide %>%
    dplyr::rename_with(~paste0("value_", .),
                       .cols = starts_with(core_variables))
  
  flat <- tidyr::pivot_longer(
    wide,
    cols = matches(core_variables), 
    names_to = c(".value", "variable_name"), 
    names_sep = '\\_')
  
  
  # Sorting and arranging rows by sample date and location 
  
  flat <- flat %>% dplyr::arrange(Date, Plot)
  
  # Add columns for the observation table -----------------------------------
  
  # Each row of the flattened source dataset represents an observation of taxa 
  # abundance and should have a unique ID for reference
  
  flat$observation_id <- seq(nrow(flat))
  
  # Observations are made at different sites
  
  flat$location_id <- flat %>% group_by(Plot) %>% group_indices()
  
  # Annual survey, event is every year
  
  flat$event_id <- flat %>% group_by(Year, CountNumber) %>% group_indices()
  
  
  # Add columns for the location table ----------------------------------------
  
  message("NOTE: no way to discern which 'plot' corresponds to which geographicDescription")
  message("latitude and longitude are average of bounding box and separate points")
  
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
  
  flat <- flat %>% dplyr::mutate(
    latitude = mean(c(north, south)),
    longitude = mean(c(east, west)))
  
  
  # Add columns for the taxon table -------------------------------------------
  
  # Resolve Taxon column values to code explanation in the metadata
  # Use the Hubbard Brook table as the definitive list of taxa
  
  dataTable <- xml2::xml_find_all(
    eml, ".//dataTable[entityDescription = 'Lepidoptera Hubbard Brook bird area']")
  taxcov <- xml2::xml_find_all(
    dataTable, ".//attribute[attributeName = 'Taxon']")
  codes <- xml2::xml_text(
    xml2::xml_find_all(taxcov, ".//code"))
  taxa <- xml2::xml_text(
    xml2::xml_find_all(taxcov, ".//definition"))
  
  tax <- data.frame(Taxon = codes,
                taxon_name = taxa)
  
  flat <- flat %>% 
    dplyr::left_join(tax, by = 'Taxon')
  
  flat$taxon_id <- flat %>% group_by(taxon_name) %>% group_indices()
  
  # While not required, resolving taxonomic entities to an authority system 
  # improves the discoverability and interoperability of the ecocomDP dataset. 
  # We can resolve taxa by sending names through taxonomyCleanr for direct 
  # matches against the Integrated Taxonomic Information System 
  # (ITIS; https://www.itis.gov/).
  
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
  
  
  dates <- flat$Date %>% na.omit() %>% sort()
  
  flat$package_id <- derived_id
  flat$original_package_id <- source_id
  flat$length_of_survey_years <- ecocomDP::calc_length_of_survey_years(dates)
  flat$number_of_years_sampled <- ecocomDP::calc_number_of_years_sampled(dates)
  flat$std_dev_interval_betw_years <- 
    ecocomDP::calc_std_dev_interval_betw_years(dates)
  flat$max_num_taxa <- length(unique(flat$taxon_name))
  flat$geo_extent_bounding_box_m2 <- 
    ecocomDP::calc_geo_extent_bounding_box_m2(min(west), max(east), max(north), min(south))
  
  
  # Odds and ends -------------------------------------------------------------
  
  # Rename source columns with an ecocomDP equivalent and 
  # remove columns of redundant information.
  
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
    variable_name = c("CountNumber", "GridLetter", "GridNumber", "TreeSpecies",
                      "SampleNumber", "Taxon"))
  
  # Create the variable_mapping table.
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary)
  
  # i <- variable_mapping$variable_name == 'NumberIndividuals'
  # variable_mapping$mapped_system[i] <- 'Darwin Core'
  # variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/individualCount'
  # variable_mapping$mapped_label[i] <- 'individualCount'
  
  # i <- variable_mapping$variable_name == 'length'
  # variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  # variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001177'
  # variable_mapping$mapped_label[i] <- 'Non-Plant Material Length'
  
  # i <- variable_mapping$variable_name == 'biomass'
  # variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  # variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001685'
  # variable_mapping$mapped_label[i] <- 'invertebrate species biomass'
  
  i <- variable_mapping$variable_name == 'Plot'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002432'
  variable_mapping$mapped_label[i] <- 'plot identifier'
  
  i <- variable_mapping$variable_name == 'TreeSpecies'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002490'
  variable_mapping$mapped_label[i] <- 'species code'
  
  i <- variable_mapping$variable_name == 'Taxon'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002490'
  variable_mapping$mapped_label[i] <- 'species code'
  
  i <- variable_mapping$variable_name == 'SampleNumber'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002989'
  variable_mapping$mapped_label[i] <- 'replicate identifier'
  
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
  # annotations" in the derived. The predicate "is about" is used, which 
  # results in an annotation that reads "This dataset is about 'species 
  # abundance'", "This dataset is about 'Population', etc.
  
  dataset_annotations <- c(
    `Lepidoptera` = 
      "http://purl.obolibrary.org/obo/NCBITaxon_7088",
    `Population` = 
      "http://purl.dataone.org/odo/ECSO_00000311",
    `organism` =
      "http://purl.obolibrary.org/obo/OBI_0100026")
  
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
      "A function for converting knb-lter-hbr.82 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation") 
  
}



# tableRE
#
# This ecocomDP helper function captures a table name from a user-provided 
# regular expression (RE) pattern
#
# Use this function when there is a possibility that a table name will change
# when L0 dataset is revised
#
# You may expect a table name will change if:
## it includes a date or range of dates (504_BNZ_Beetles_Kruse_1975-2013.txt)
## it includes a version number (ntl11_1_v7.csv)
## it includes a randomly generated hash (643_mcdowell_arthropod_sites_7f6c04e69ade998a30f3b5a73b2206f8.csv)
#
# Example -----------------------------------------------------------------
# 
# source_id <- "knb-lter-cap.643.3"
# 
# eml <- EDIutils::api_read_metadata(source_id)
# data <- EDIutils::read_tables(
#   eml = eml, 
#   strip.white = TRUE,
#   na.strings = "",
#   convert.missing.value = TRUE, 
#   add.units = TRUE)
# 
# # > data %>% names()
# # > [1] "643_mcdowell_arthropod_sites_7f6c04e69ade998a30f3b5a73b2206f8.csv"      
# # > [2] "643_mcdowell_pitfall_arthropods_fbe31c21e9a5a1d916e7911727dca04b.csv"   
# # > [3] "643_mcdowell_vegetation_arthropods_ea9c8c6b35bc8776480984156f3cfb13.csv"
# 
# sites <- tableRE(data, "(643_mcdowell_arthropod_sites_)(.+)")
# traps <- tableRE(data, "(643_mcdowell_pitfall_arthropods_)(.+)")
# veg <- tableRE(data, "(643_mcdowell_vegetation_arthropods_)(.+)")

# Function Definition -----------------------------------------------------

library(stringr)

tableRE <- function(data,
                    pattern) {
  
  data_names <- as.list(names(data))
  
  data_string <- stringr::str_extract(
    data_names, pattern)
  
  data_string <- data_string[!is.na(data_string)]
  
  return(data[[data_string]])
}

