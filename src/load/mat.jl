# Loading MATLAB `.mat` files (CMRxRecon2024 distributes k-space as v7.3 .mat).
# MAT.jl auto-detects the format and reads v7.3 (HDF5-based) natively.

"""
    load_mat(x) -> Dict{String,Any}

Load a MATLAB `.mat` file into a `Dict` mapping variable name to value. `x` may be:

- a path to a `.mat` file;
- a [`DatasetEntry`](@ref) or [`DatasetHandle`](@ref) — it is downloaded (cached)
  first via [`download_dataset`](@ref), then loaded.

Used primarily for CMRxRecon2024, whose k-space data ships as v7.3 `.mat` files.

```julia
e = list_datasets(CMRXRECON2024; offline = true)[1]
data = load_mat(e)            # downloads + reads
keys(data)                    # e.g. "kspace_full", "kspace_sub", ...
```
"""
load_mat(path::AbstractString) = MAT.matread(String(path))
load_mat(e::DatasetEntry; kwargs...) = load_mat(download_dataset(e; kwargs...))
load_mat(h::DatasetHandle; kwargs...) = load_mat(h.entry; kwargs...)
