# Plan Smell Reference

Shared lookup table used by Step 6 (live plan-smell detection) and Step 7 (per-query plan
analysis) to translate detected anti-patterns into actionable fixes.

| Flag column | What it means | Typical fix |
|-------------|--------------|-------------|
| `has_implicit_conversion` | A `CONVERT_IMPLICIT` in scalar expressions — often causes index scans instead of seeks | Match data types between columns and parameters/literals |
| `has_spill_to_tempdb` | Sort or Hash operator spilled to disk because its working set exceeded the available grant | Correct estimates and row width first; consider a memory-grant hint only after validating the workload impact |
| `has_missing_index_suggestion_in_plan` | Optimizer found a missing index that could reduce cost | Evaluate and create the suggested index |
| `has_key_lookup_in_plan` | Key Lookup after a non-covering index seek — causes extra I/O and CPU per row | Add covering `INCLUDE` columns to the seek index |
| `has_scalar_udf_in_plan` | Scalar T-SQL UDF in the plan — prevents parallelism, forces row-by-row execution | Rewrite as inline table-valued function or inline expression |
