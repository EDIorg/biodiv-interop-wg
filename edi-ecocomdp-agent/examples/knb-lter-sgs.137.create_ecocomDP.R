#-----------------------------------------------------------------------------
# This function converts source dataset "knb-lter-sgs.137" (archived in the EDI
# Data Repository) to ecocomDP dataset "edi.329" (also archived in EDI)
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
#             "edi.329" whenever new data are added to the source 
#             "knb-lter-sgs.137". The framework executing this maintenance 
#             routine is hosted on a remote server and jumps into action 
#             whenever an update notification is received for 
#             "knb-lter-sgs.137". The maintenance routine parses the 
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "knb-lter-sgs.137":
# https://portal.edirepository.org/nis/mapbrowse?scope=knb-lter-sgs&identifier=137
# Landing page to derived dataset "edi.329":
# https://portal.edirepository.org/nis/mapbrowse?scope=edi&identifier=329
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
  
  data <- cols_to_attrs_rename(eml, data)[[1]] %>% 
    rename(`Stapp's comments` = `Stapp comments`)
  
  # Flatten source dataset --------------------------------------------------
  
  wide <- data %>% dplyr::rename("value_WT" = "WT")
  
  flat <- wide %>% 
    tidyr::pivot_longer(cols = matches(c("WT")),
                        names_to = c(".value", "variable_name"),
                        names_sep = "\\_")
  
  # Sorting and arranging rows by sample date and location 
  
  flat <- flat %>% dplyr::arrange(as.numeric(Sample), as.numeric(Day))
  
  # Add columns for the observation table -----------------------------------
  
  flat$observation_id <- seq(nrow(flat))
  
  
  # Location is at the level where trapping webs are located
  
  flat$location_id <- flat %>% group_by(Web) %>% group_indices()
  
  # Each sample value in the table represents a different event
  # For events spanning multiple days, the sample number adds a decimal value
  
  flat$event_id <- flat %>%
    group_by(as.numeric(Sample)) %>% group_indices()
  
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
    rename(taxon_name = Spp)
  
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
  
  # derive iso8601 datetime from the components in the table
  
  flat$datetime <- lubridate::ymd(
    paste0(flat$Year,"-", flat$Month, "-", flat$Day))
  
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
    location_name = c("Web"),
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
    variable_name = c("Sample", "Session", "Veg", "Night", "Trap", "Capt", "Tag",
                      "Age", "Sex", "Reprod", "notes", "Stapp's comments"),
    unit = c("unit_Night", "unit_Trap"))
  
  # Create the variable_mapping table.
  
  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation,
    observation_ancillary = observation_ancillary)
  
  i <- variable_mapping$variable_name == 'WT'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://ecoinformatics.org/oboe/oboe.1.2/oboe-characteristics.owl#Mass'
  variable_mapping$mapped_label[i] <- 'Mass'
  
  i <- variable_mapping$variable_name == 'Sample'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventID'
  variable_mapping$mapped_label[i] <- 'eventID'
  
  i <- variable_mapping$variable_name == 'Session'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventID'
  variable_mapping$mapped_label[i] <- 'eventID'
  
  i <- variable_mapping$variable_name == 'Night'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002123'
  variable_mapping$mapped_label[i] <- 'days elapsed'
  
  i <- variable_mapping$variable_name == 'Trap'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002372'
  variable_mapping$mapped_label[i] <- 'trap identifier'
  
  i <- variable_mapping$variable_name == 'Tag'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00001217'
  variable_mapping$mapped_label[i] <- 'Tag Number'
  
  i <- variable_mapping$variable_name == 'Sex'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/sex'
  variable_mapping$mapped_label[i] <- 'sex'
  
  i <- variable_mapping$variable_name == 'notes'
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventRemarks'
  variable_mapping$mapped_label[i] <- 'eventRemarks'
  
  i <- variable_mapping$variable_name == "Stapp's comments"
  variable_mapping$mapped_system[i] <- 'Darwin Core'
  variable_mapping$mapped_id[i] <- 'http://rs.tdwg.org/dwc/terms/eventRemarks'
  variable_mapping$mapped_label[i] <- 'eventRemarks'
  
  i <- variable_mapping$variable_name == 'Veg'
  variable_mapping$mapped_system[i] <- 'The Ecosystem Ontology'
  variable_mapping$mapped_id[i] <- 'http://purl.dataone.org/odo/ECSO_00002207'
  variable_mapping$mapped_label[i] <- 'type of vegetation'


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
    `Mammalia` = 
      "http://purl.obolibrary.org/obo/NCBITaxon_40674",
    `grassland ecosystem` = 
      "http://purl.obolibrary.org/obo/ENVO_01001206",
    `shrubland biome` = 
      "http://purl.obolibrary.org/obo/ENVO_01000176")
  
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
      "A function for converting knb-lter-sgs.137 to ecocomDP",
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
