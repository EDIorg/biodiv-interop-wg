# -----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-pie.404" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.338" (also archived in EDI)
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
#             "edi.338" whenever new data are added to the source 
#             "knb-lter-pie.404". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-pie.404". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-pie.404":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-pie&identifier=404
# Landing page to derived dataset "edi.338":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=338
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
  
  # The source dataset is about phytoplankton communities across a salinity 
  # gradient at the Plum Island Sound Estuary. The dataset consists of a single
  # table listing chlorophyll a concentration by taxa group.
  
  # Read the source dataset from EDI
  
  eml <- EDIutils::api_read_metadata(source_id)
  data <- EDIutils::read_tables(
    eml = eml, 
    strip.white = TRUE,
    na.strings = "",
    convert.missing.value = TRUE, 
    add.units = TRUE)
  data <- cols_to_attrs_rename(eml, data)
  phytos <- data$`EST-PR-PlanktonChemTax.csv`
  phytos <- dplyr::rename(phytos, datetime = DATE)
  phytos$datetime <- lubridate::ymd(phytos$datetime)
  
  
  # Flatten the source dataset ------------------------------------------------
  
  # Gather taxon group chla concentration groups and convert wide format to 
  # "flat" format.
  
  wide <- tidyr::pivot_longer(
    data = phytos, 
    cols = c("Diatoms", "Cryptophytes", "Dinoflagellates", "Euglenophytes", 
             "Prasinophytes", "Haptophytes", "Cyanobacteria"), 
    names_to = "taxon_name", 
    values_to = "value")
  wide$variable_name <- "chlorophyll relative abundance"
  wide$unit <- "microgramPerLiter"
  flat <- wide
  
  # Add columns for the observation table -------------------------------------
  
  # Surveys were approximately conducted in the spring and fall of each year, 
  # with every month sampled from April through Dec but not more than once per 
  # month. So we'll uniquely identify surveys by grouping on month and year.
  
  flat$event_id <- flat %>% 
    group_by(year = lubridate::year(flat$datetime),
             month = lubridate::month(flat$datetime)) %>% 
    group_indices()
  flat <- flat %>% arrange(event_id)
  
  # Observations are made at stations nested in the estuary
  
  flat$location_id <- flat %>% group_by(Site) %>% group_indices()
  
  # Each row of the flattened source dataset represents an observation of taxa 
  # abundance and should have a unique ID for reference
  
  flat$observation_id <- seq(nrow(flat))
  
  # Add columns for the location table ----------------------------------------
  
  # Assign coordinates to sites as an average throughout the history of this
  # dataset. We use an average because of variance in the exact positioning of
  # the sampling platform. The raw coordinates will be stashed in observation 
  # ancillary for full reproducibility.
  
  coords <- flat %>% 
    dplyr::select(Site, Latitude, Longitude) %>% 
    dplyr::mutate(Latitude = as.numeric(Latitude),
                  Longitude = as.numeric(Longitude)) %>% 
    dplyr::group_by(Site) %>% 
    dplyr::summarise(latitude = mean(Latitude, na.rm = TRUE),
                     longitude = mean(Longitude, na.rm = TRUE))
  
  # Join to flat
  
  flat <- dplyr::left_join(flat, coords, by = "Site")
  
  # Add columns for the taxon table -------------------------------------------
  
  # Taxonomic entities are classified in broad groups
  
  flat$taxon_id <- flat %>% group_by(taxon_name) %>% group_indices()
  
  # Improve taxonomic data by replacing colloquial names with names resolvable 
  # to an authority system. Stash the original colloquial names in the 
  # taxon ancillary.
  
  taxa_map <- data.frame(
    taxon_name = c("Diatoms", "Cryptophytes", "Dinoflagellates", 
                   "Euglenophytes", "Prasinophytes", "Haptophytes", 
                   "Cyanobacteria"),
    sci_name = c("Khakista", "Cryptophyta", "Dinozoa", 
                 "Euglenophyceae", "Prasinophyceae", "Haptophyta", 
                 "Cyanobacteria"))
  flat <- dplyr::left_join(flat, taxa_map, by = "taxon_name")
  flat <- dplyr::rename(flat, 
                        common_name = taxon_name,
                        taxon_name = sci_name)
  
  # While not required, resolving taxonomic entities to an authority system 
  # improves the discoverability and interoperability of the ecocomDP dataset. 
  # We can resolve taxa by sending names through taxonomyCleanr for direct 
  # matches against the Integrated Taxonomic Information System 
  # (ITIS; https://www.itis.gov/).
  
  taxa_resolved <- taxonomyCleanr::resolve_sci_taxa(
    x = unique(flat$taxon_name),
    data.sources = 9)
  
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
    location_name = c("Site"), 
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
    variable_name = c("SampleName", "SubsampleName", "BottleName", "SampleType",
                      "Volume", "TEMP", "Salinity", "TotalChlA", "Comments",
                      "Latitude", "Longitude", "Distance"),
    unit = c("unit_Volume", "unit_TEMP", "unit_Salinity", "unit_TotalChlA", 
             "unit_Latitude", "unit_Longitude", "unit_Distance"))
  
  # Create the variable_mapping table
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary)
  
  i <- variable_mapping$variable_name == 'chlorophyll relative abundance'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002280'
  variable_mapping$mapped_label[i] <- 'chlorophyll relative abundance'
  
  i <- variable_mapping$variable_name == 'SampleName'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/materialSampleID'
  variable_mapping$mapped_label[i] <- 'materialSampleID'
  
  i <- variable_mapping$variable_name == 'SubsampleName'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/materialSampleID'
  variable_mapping$mapped_label[i] <- 'materialSampleID'
  
  i <- variable_mapping$variable_name == 'BottleName'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/materialSampleID'
  variable_mapping$mapped_label[i] <- 'materialSampleID'
  
  i <- variable_mapping$variable_name == 'Volume'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002225'
  variable_mapping$mapped_label[i] <- 'water sample volume'
  
  i <- variable_mapping$variable_name == 'TEMP'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001227'
  variable_mapping$mapped_label[i] <- 'Water Temperature'
  
  i <- variable_mapping$variable_name == "Salinity"
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001164'
  variable_mapping$mapped_label[i] <- 'Water Salinity'
  
  i <- variable_mapping$variable_name == "Salinity"
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001164'
  variable_mapping$mapped_label[i] <- 'Water Salinity'
  
  i <- variable_mapping$variable_name == 'TotalChlA'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00000516'
  variable_mapping$mapped_label[i] <- 'Chlorophyll-a Concentration'
  
  i <- variable_mapping$variable_name == 'Comments'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventRemarks'
  variable_mapping$mapped_label[i] <- 'eventRemarks'
  
  i <- variable_mapping$variable_name == 'Latitude'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'decimalLatitude'
  variable_mapping$mapped_label[i] <- 'http://rs.tdwg.org/dwc/terms/decimalLatitude'
  
  i <- variable_mapping$variable_name == 'Longitude'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/decimalLongitude'
  variable_mapping$mapped_label[i] <- 'decimalLongitude'
  
  i <- variable_mapping$variable_name == 'Distance'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001710'
  variable_mapping$mapped_label[i] <- 'distance'
  
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
    `chlorophyll relative abundance` = "http://purl.dataone.org/odo/ECSO_00002280",
    `ecological community` = "http://purl.obolibrary.org/obo/PCO_0000002",
    estuary = "http://purl.obolibrary.org/obo/ENVO_00000045",
    phytoplankton = "http://purl.dataone.org/odo/ECSO_00000504")
  
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
      "A function for converting knb-lter-pie.404 to ecocomDP",
    contact = additional_contact,
    user_id = 'ecocomdp',
    user_domain = 'EDI',
    basis_of_record = "HumanObservation")
  
}








# Rename table columns to EML attributes
# 
# @param eml (xml_document xml_node) EML metadata
# @param data (named list of data.frame) Tables described by \code{eml}
# 
# @return (named list of data.frame) \code{data} with table columns renamed to EML attributeName, when a direct one-to-one match of lowercased versions occur, otherwise the column name is used.
# 
# @examples
# eml <- EDIutils::api_read_metadata("knb-lter-knz.26.11")
# data <- EDIutils::read_tables(eml)
# data <- cols_to_attrs_rename(eml, data)
#
cols_to_attrs_rename <- function(eml, data) {
  r <- lapply(
    names(data),
    function(nm) {
      # Compare columns
      cols <- colnames(data[[nm]])
      atts <- xml2::xml_text(xml2::xml_find_all(eml, paste0(".//dataTable[physical/objectName = '", nm, "']//attributeName")))
      # Rename columns with attribute names when there is a match, otherwise use column name
      df_cols <- data.frame(
        cols = cols,
        lower = tolower(cols),
        stringsAsFactors = FALSE)
      df_atts <- data.frame(
        atts = atts,
        lower = tolower(atts),
        stringsAsFactors = FALSE)
      map_cols2atts <- dplyr::left_join(df_cols, df_atts, by = "lower")
      newcols <- map_cols2atts$atts
      newcols[which(is.na(map_cols2atts$atts))] <- cols[which(is.na(map_cols2atts$atts))]
      colnames(data[[nm]]) <- newcols
      return(data[[nm]])
    })
  names(r) <- names(data)
  return(r)
}
