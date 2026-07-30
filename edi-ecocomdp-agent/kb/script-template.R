#-----------------------------------------------------------------------------
# This function converts source dataset "{{source_id}}" (archived in the EDI
# Data Repository) to ecocomDP dataset "{{derived_id}}" (also archived in EDI)
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
#             "{{derived_id}}" whenever new data are added to the source
#             "{{source_id}}". The framework executing this maintenance
#             routine is hosted on a remote server and jumps into action
#             whenever an update notification is received for
#             "{{source_id}}". The maintenance routine parses the
#             notification to get the arguments to create_ecocomDP().
#
# Landing page to source dataset "{{source_id}}":
# https://portal.edirepository.org/nis/mapbrowse?scope={{source_scope}}&identifier={{source_identifier}}
# Landing page to derived dataset "{{derived_id}}":
# https://portal.edirepository.org/nis/mapbrowse?scope={{derived_scope}}&identifier={{derived_identifier}}
# -----------------------------------------------------------------------------

# Libraries used by this function

library(ecocomDP)
library(xml2)
library(magrittr)
library(data.table)
library(lubridate)
library(tidyr)
library(dplyr)
library(readr)
library(EDIutils)       # >= 1.0; remotes::install_github("EDIorg/EDIutils")
library(taxonomyCleanr) # remotes::install_github("EDIorg/taxonomyCleanr")

# Rebuild the unit_<column> columns that EDIutils::read_tables(add.units = TRUE)
# used to append. EDIutils >= 1.0 removed read_tables(); read_data_entity()
# returns raw bytes with no metadata attached, so units must now be read from the
# EML attributeList.
#
# Attributes that declare no unit are skipped, so a source with no units passes
# through unchanged. These named columns are what create_*_ancillary(unit = ...)
# consumes — if this adds nothing, those arguments reference columns that do not
# exist and the create_* call fails.

add_unit_columns <- function(x, eml, entity_name) {
  attrs <- xml2::xml_find_all(
    eml,
    paste0(".//dataTable[entityName[normalize-space()='", entity_name, "']]",
           "/attributeList/attribute"))
  for (attr in attrs) {
    nm <- xml2::xml_text(xml2::xml_find_first(attr, "./attributeName"))
    un <- xml2::xml_text(
      xml2::xml_find_first(attr, ".//standardUnit | .//customUnit"))
    if (!is.na(nm) && !is.na(un) && nm %in% colnames(x)) {
      x[[paste0("unit_", nm)]] <- un
    }
  }
  x
}

create_ecocomDP <- function(path,
                            source_id,
                            derived_id,
                            url = NULL) {

  # Read source dataset -------------------------------------------------------

  # EDIutils >= 1.0 replaced api_read_metadata() with read_metadata() and removed
  # read_tables() altogether. Data entities are now fetched one at a time by
  # entity id and parsed by the caller.
  #
  # Select entities by entityName, not by position: read_data_entity_names()
  # returns otherEntity objects alongside dataTables, and the order is the order
  # they appear in the EML, which is not guaranteed across package revisions.
  #
  # `na` should be exactly the missingValueCode values the source EML declares
  # (recorded per column in profile.json). Do not add speculative sentinels such
  # as "." or "-9999": if the source does not declare them, a legitimate value
  # silently becomes NA.

  eml <- EDIutils::read_metadata(source_id)
  entities <- EDIutils::read_data_entity_names(source_id)

  {{read_entity_assignments}}

  # Flatten source dataset ----------------------------------------------------

  {{flatten_block}}

  # Extract units from EML ----------------------------------------------------

  # Applied to `flat` rather than to the source table: unit values are constant
  # per column, so the result is identical, and this way the columns cannot be
  # dropped by an intervening join, filter or pivot. Any row added by zero-fill
  # or aggregation inherits the unit string too.

  {{units_block}}

  # Add columns for the observation table -------------------------------------

  flat$observation_id <- seq(nrow(flat))

  {{location_id_block}}

  {{event_id_block}}

  # Add columns for the location table ----------------------------------------

  {{location_block}}

  # Add columns for the taxon table -------------------------------------------

  {{taxon_block}}

  # Add columns for the dataset_summary table ---------------------------------

  dates <- {{dates_expr}}

  flat$package_id <- derived_id
  flat$original_package_id <- source_id
  flat$length_of_survey_years <- ecocomDP::calc_length_of_survey_years(dates)
  flat$number_of_years_sampled <- ecocomDP::calc_number_of_years_sampled(dates)
  flat$std_dev_interval_betw_years <-
    ecocomDP::calc_std_dev_interval_betw_years(dates)
  flat$max_num_taxa <- length(unique(flat$taxon_name))
  flat$geo_extent_bounding_box_m2 <-
    ecocomDP::calc_geo_extent_bounding_box_m2(
      min(flat${{longitude_col}}, na.rm = TRUE),
      max(flat${{longitude_col}}, na.rm = TRUE),
      max(flat${{latitude_col}}, na.rm = TRUE),
      min(flat${{latitude_col}}, na.rm = TRUE))

  # Odds and ends -------------------------------------------------------------

  # Rename source columns with an ecocomDP equivalent

  flat <- flat %>%
    dplyr::rename(datetime = {{datetime_col}})

  flat$author <- NA_character_

  # Parse flat into ecocomDP tables --------------------------------------------

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
    location_name = c({{location_name_cols}}),
    latitude = "{{latitude_col}}",
    longitude = "{{longitude_col}}")

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
  #
  # RENDERER: emit ONLY the ancillary tables declared in the mapping spec.
  # Every table named here must also appear in create_variable_mapping() and
  # write_tables() below, and vice versa. Mismatch is the ntl.356 bug.

  {{ancillary_blocks}}

  # Create the variable_mapping table. This is optional but highly recommended
  # as it provides unambiguous definitions to variables and facilitates
  # integration with other ecocomDP datasets.

  variable_mapping <- ecocomDP::create_variable_mapping(
    observation = observation{{variable_mapping_args}})

  {{annotation_assignments}}

  # Write tables to file

  ecocomDP::write_tables(
    path = path,
    observation = observation,
    location = location,
    taxon = taxon,
    dataset_summary = dataset_summary{{write_tables_args}},
    variable_mapping = variable_mapping)

  # Validate tables -----------------------------------------------------------

  issues <- ecocomDP::validate_data(path = path)

  # Create metadata -----------------------------------------------------------

  # Convert "dataset level keywords" listed in the source to "dataset level
  # annotations" in the derived. The predicate "is about" is used, which
  # results in an annotation that reads "This dataset is about 'species
  # abundance'", "This dataset is about 'Population'", etc.

  dataset_annotations <- c(
    {{dataset_annotations}})

  # Add contact information for the author of this script and dataset

  additional_contact <- data.frame(
    givenName = '{{contact_givenName}}',
    surName = '{{contact_surName}}',
    organizationName = '{{contact_organizationName}}',
    electronicMailAddress = '{{contact_email}}',
    stringsAsFactors = FALSE)

  # Create EML metadata

  eml <- ecocomDP::create_eml(
    path = path,
    source_id = source_id,
    derived_id = derived_id,
    is_about = dataset_annotations,
    script = "create_ecocomDP.R",
    script_description =
      "A function for converting {{source_id}} to ecocomDP",
    contact = additional_contact,
    user_id = '{{user_id}}',
    user_domain = '{{user_domain}}',
    basis_of_record = "{{basis_of_record}}")

}
