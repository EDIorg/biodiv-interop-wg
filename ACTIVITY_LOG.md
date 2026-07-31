# Current activity for the group

## Collect datasets to map between different standards

## Review and refine the `edi-ecocomdp-agent`

The `edi-ecocomdp-agent` is mostly AI generated, so it needs review and refinement. Probably the most important thing to do there is make sure it prompts the human curator successfully to determine what the observed variables and observational units are, and how those should be aggregated and formatted into the resulting ecocomDP dataset.

For example:

* Should individual occurrences in a survey dataset (transect, say) be aggregated into counts for abundance? 
* At what observational unit should they be aggregated (transect, site, etc).
* Do plot or site-level densities (like percent cover?) ever need to be aggregated? How?
* What additional variables need to be placed in the ancillary tables and how are they aggregated?

It would make sense to develop some use-cases for biodiversity and ecology data of different types and with different designs, and then proceed through a conversion to see how the agent handles these questions and how the human-in-the loop can respond appropriately.