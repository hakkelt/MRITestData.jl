#!/usr/bin/env julia
#
# Phase 1c maintainer tool (optional) — generate data/cmrxrecon2024_filemeta.csv.
#
# Records the k-space variable name and array shape for each `.mat` file so the
# catalog can be enriched with image dimensions / coil counts without downloading
# data at runtime. CMRxRecon2024 `.mat` files are MATLAB v7.3 (HDF5), so shapes are
# read straight from the HDF5 dataset metadata — no array payload is loaded.
#
# Usage:
#   julia --project=. scripts/extract_cmrxrecon2024_filemeta.jl <mat_dir> [out.csv]
#
# <mat_dir> is a directory tree of extracted `.mat` files (e.g. a partial local copy
# of the dataset). Paths are recorded relative to <mat_dir>.

import HDF5

# HDF5 stores MATLAB arrays with dimensions reversed relative to MATLAB; we report
# them in MATLAB order (reverse of the HDF5 dataspace) for consistency with MAT.jl.
function dataset_shape(ds::HDF5.Dataset)
    return reverse(size(ds))
end

# Walk one .mat (v7.3/HDF5) file and return (varname, shape) for the largest dataset
# (the k-space array dominates file size). Returns nothing if no dataset is found.
function main_variable(path::AbstractString)
    return HDF5.h5open(path, "r") do f
        best_name = ""
        best_shape = Int[]
        best_count = -1
        for name in keys(f)
            obj = f[name]
            obj isa HDF5.Dataset || continue
            shp = collect(Int, dataset_shape(obj))
            n = isempty(shp) ? 0 : prod(shp)
            if n > best_count
                best_count = n
                best_name = String(name)
                best_shape = shp
            end
        end
        best_count < 0 ? nothing : (best_name, best_shape)
    end
end

function main(args)
    length(args) >= 1 || error("usage: julia extract_cmrxrecon2024_filemeta.jl <mat_dir> [out.csv]")
    root = args[1]
    out = length(args) >= 2 ? args[2] :
        normpath(joinpath(@__DIR__, "..", "data", "cmrxrecon2024_filemeta.csv"))

    rows = Tuple{String, String, String}[]
    for (dir, _, files) in walkdir(root)
        for f in files
            endswith(f, ".mat") || continue
            full = joinpath(dir, f)
            rel = relpath(full, root)
            try
                mv = main_variable(full)
                mv === nothing && continue
                name, shape = mv
                push!(rows, (rel, name, join(shape, "x")))
            catch err
                @warn "skipping unreadable file" file = rel exception = err
            end
        end
    end

    open(out, "w") do io
        println(io, "path,variable,shape")
        for (p, v, s) in sort(rows; by = first)
            println(io, join((p, v, s), ","))
        end
    end
    return @info "wrote filemeta" out files = length(rows)
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
