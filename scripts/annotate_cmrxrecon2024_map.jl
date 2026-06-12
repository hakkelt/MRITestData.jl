#!/usr/bin/env julia
#
# Maintainer tool — add derived metadata columns to cmrxrecon2024_map.csv.
#
# Run this after generate_cmrxrecon2024_map.jl when you want to re-annotate without
# re-parsing the 835 GB archive. All path-derived annotations require only the CSV;
# acquisition-parameter annotations also need the extracted info-CSV directory.
#
# Usage:
#   julia scripts/annotate_cmrxrecon2024_map.jl [input.csv] [output.csv] [--info-dir <dir>]
#
# If output is omitted, the input file is updated in place.
# If input is omitted, defaults to data/cmrxrecon2024_map.csv.
# --info-dir points to the directory that contains the extracted *_info.csv files
#   (e.g. ~/c_mrrecon/CMRxRecon2024/home2).
#
# Added columns (idempotent — existing annotation columns are replaced):
#   Path-derived:
#     role          "fullsample" | "undersampled" | "mask" | ""
#     sampling      e.g. "Uniform4", "ktRadial20", "full"
#     coil_type     "multi" | "single" | ""
#     modality      e.g. "Cine", "Aorta" | ""
#     dataset_set   "TrainingSet" | "ValidationSet" | "TestSet" | ""
#     subject       e.g. "P001" | ""
#     matfile       filename component, e.g. "cine_sax.mat"
#     mask_path     paired mask archive path (undersampled only) | ""
#     has_fullsample "true" | "false"
#   Acquisition-parameter (requires --info-dir):
#     coils         integer, e.g. "30"
#     field_strength real field strength in T, e.g. "2.89362"
#     fov_x         FOV in readout direction (mm)
#     fov_y         FOV in phase direction (mm)
#     nx            reconstruction matrix readout
#     ny            reconstruction matrix phase
#     nz            number of slices
#     nt            number of temporal/weighted phases
#     tr_ms         TR in ms
#     te_ms         TE in ms
#     flip_angle    flip angle in degrees

using DelimitedFiles

const MODALITIES = ("Cine", "Aorta", "Mapping", "Tagging", "Flow2d", "BlackBlood")
const SETS = ("TrainingSet", "ValidationSet", "TestSet")

# ── Path-derived helpers ──────────────────────────────────────────────────────

function _cmr_role(path)
    occursin("FullSample", path) && return "fullsample"
    occursin("UnderSample_Task", path) && return "undersampled"
    occursin("Mask_Task", path) && return "mask"
    return ""
end

function _cmr_sampling(matfile)
    m = match(r"_(?:kus|mask)_([^.]+)\.mat$", matfile)
    m === nothing && return "full"
    cap = m.captures[1]
    return cap === nothing ? "full" : String(cap)
end

function _cmr_coil_type(path)
    occursin("SingleCoil", path) && return "single"
    occursin("MultiCoil", path) && return "multi"
    return ""
end

function _cmr_modality(path)
    for mod in MODALITIES
        occursin(mod, path) && return mod
    end
    return ""
end

function _cmr_dataset_set(path)
    for s in SETS
        occursin(s, path) && return s
    end
    return ""
end

function _cmr_subject(path)
    m = match(r"/P(\d+)/", path)
    return m === nothing ? "" : "P" * m.captures[1]
end

function _cmr_matfile(path)
    return String(last(split(path, '/')))
end

# Paired mask archive path for an undersampled entry, or "" if not applicable/missing.
function _cmr_mask_path(path, path_set)
    occursin("UnderSample_Task", path) || return ""
    mp = replace(path, "UnderSample_Task" => "Mask_Task")
    mp = replace(mp, "_kus_" => "_mask_")
    return mp in path_set ? mp : ""
end

# "true" if a FullSample counterpart (same modality/subject/stem, in either
# TrainingSet or ValidationSet) exists in the archive.
function _cmr_has_fullsample(path, path_set)
    m = match(
        r"^((?:[^/]+/)*?[^/]+/)(?:Training|Validation)Set/UnderSample_Task\d+(/[^/]+/)([^/]+)_kus_[^/]+\.mat$",
        path,
    )
    m === nothing && return "false"
    prefix, subject_dir, stem = m.captures
    for set in ("TrainingSet", "ValidationSet")
        in(string(prefix, set, "/FullSample", subject_dir, stem, ".mat"), path_set) && return "true"
    end
    return "false"
end

# ── Acquisition-parameter helpers ─────────────────────────────────────────────

# Strip the undersampling/mask suffix to recover the base acquisition stem.
# e.g. "cine_sax_kus_Uniform4.mat" -> "cine_sax"
#      "T1map_mask_ktRadial4.mat"  -> "T1map"
#      "cine_sax.mat"              -> "cine_sax"
function _cmr_acquisition_stem(matfile)
    s = replace(matfile, r"_(?:kus|mask)_[^.]+\.mat$" => "")
    return replace(s, r"\.mat$" => "")
end

# Load all *_info.csv files under info_dir into a lookup table keyed by
# (modality, subject, stem). Each value is a Dict{String,String} of parameters.
# The info CSVs live at:
#   <info_dir>/.../<Modality>/TrainingSet/ImgSnapshot/<Subject>/<stem>_info.csv
function _load_info_csvs(info_dir::AbstractString)
    lookup = Dict{Tuple{String, String, String}, Dict{String, String}}()
    for (root, _, files) in walkdir(info_dir)
        for file in files
            endswith(file, "_info.csv") || continue
            parts = splitpath(root)
            imgsnap_idx = findlast(==("ImgSnapshot"), parts)
            imgsnap_idx === nothing && continue
            imgsnap_idx >= length(parts) && continue
            subject = parts[imgsnap_idx + 1]
            modality = ""
            for p in parts
                if p in MODALITIES
                    modality = p
                    break
                end
            end
            isempty(modality) && continue
            stem = file[1:(end - length("_info.csv"))]
            params = Dict{String, String}()
            for line in eachline(joinpath(root, file))
                kv = split(line, ','; limit = 2)
                length(kv) == 2 || continue
                k = strip(kv[1])
                k == "Parameter" && continue
                params[k] = strip(kv[2])
            end
            lookup[(modality, subject, stem)] = params
        end
    end
    return lookup
end

# Retrieve one parameter value from the lookup, trying multiple candidate keys.
function _info_val(lookup, modality, subject, stem, keys...)
    params = get(lookup, (modality, subject, stem), nothing)
    params === nothing && return ""
    for k in keys
        haskey(params, k) && return params[k]
    end
    return ""
end

# ── Column manifest ───────────────────────────────────────────────────────────

# Columns added (or replaced) by this script. Must stay in sync with
# _cmrxrecon_entry in src/catalog/cmrxrecon2024_catalog.jl.
const ANNOTATION_COLS = [
    # path-derived
    "role", "sampling", "coil_type", "modality", "dataset_set",
    "subject", "matfile", "mask_path", "has_fullsample",
    # acquisition parameters (populated when --info-dir is supplied)
    # hardware_coils = physical receiver coil elements (not the 10 virtual stored channels)
    "hardware_coils", "field_strength", "fov_x", "fov_y",
    "nx", "ny", "nz", "nt", "tr_ms", "te_ms", "flip_angle",
]

# ── Core annotation ───────────────────────────────────────────────────────────

function annotate(inpath, outpath; info_dir = nothing)
    data, header = readdlm(inpath, ','; header = true)
    col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(header)))
    haskey(col, "path") || error("input CSV has no 'path' column")

    nrows = size(data, 1)
    paths = [strip(String(data[r, col["path"]])) for r in 1:nrows]
    path_set = Set(paths)

    # Path-derived vectors (pre-compute shared fields once).
    modalities = [_cmr_modality(p) for p in paths]
    subjects = [_cmr_subject(p) for p in paths]
    matfiles = [_cmr_matfile(p) for p in paths]

    annotations = Dict{String, Vector{String}}(
        "role" => [_cmr_role(p) for p in paths],
        "sampling" => [_cmr_sampling(matfiles[r]) for r in 1:nrows],
        "coil_type" => [_cmr_coil_type(p) for p in paths],
        "modality" => modalities,
        "dataset_set" => [_cmr_dataset_set(p) for p in paths],
        "subject" => subjects,
        "matfile" => matfiles,
        "mask_path" => [_cmr_mask_path(p, path_set) for p in paths],
        "has_fullsample" => [_cmr_has_fullsample(p, path_set) for p in paths],
    )

    # Acquisition parameters from info CSVs.
    info_lookup = info_dir === nothing ? nothing : _load_info_csvs(info_dir)
    if info_lookup !== nothing
        @info "loaded info CSVs" entries = length(info_lookup)
    end
    function acq(r, keys...)
        info_lookup === nothing && return ""
        return _info_val(
            info_lookup,
            modalities[r],
            subjects[r],
            _cmr_acquisition_stem(matfiles[r]),
            keys...,
        )
    end
    for (col_name, param_keys) in [
            ("hardware_coils", ("CoilNumber",)),
            ("field_strength", ("FieldStrength",)),
            ("fov_x", ("FOVx",)),
            ("fov_y", ("FOVy",)),
            ("nx", ("ReconMatrix_X",)),
            ("ny", ("ReconMatrix_Y",)),
            ("nz", ("SliceNum",)),
            ("nt", ("TemporalPhase", "WeightedNum")),
            ("tr_ms", ("TR(ms)",)),
            ("te_ms", ("TE(ms)",)),
            ("flip_angle", ("FlipAngle(degree)",)),
        ]
        annotations[col_name] = [acq(r, param_keys...) for r in 1:nrows]
    end

    # Build output: original non-annotation columns first, then all annotation columns.
    orig_cols = [strip(String(h)) for h in vec(header)]
    base_cols = [c for c in orig_cols if c ∉ ANNOTATION_COLS]
    out_cols = vcat(base_cols, ANNOTATION_COLS)

    tmp = outpath * ".part"
    open(tmp, "w") do io
        println(io, join(out_cols, ","))
        for r in 1:nrows
            vals = String[]
            for c in out_cols
                if haskey(annotations, c)
                    push!(vals, annotations[c][r])
                else
                    v = data[r, col[c]]
                    push!(vals, v isa AbstractString ? strip(String(v)) : string(v))
                end
            end
            println(io, join(vals, ","))
        end
    end
    mv(tmp, outpath; force = true)

    n_with_acq = count(!isempty, annotations["hardware_coils"])
    @info "annotation done" rows = nrows acq_params = n_with_acq out = outpath
    return outpath
end

# ── Entry point ───────────────────────────────────────────────────────────────

function main(args)
    # Parse --info-dir flag anywhere in args.
    info_dir = nothing
    remaining = String[]
    i = 1
    while i <= length(args)
        if args[i] == "--info-dir" && i < length(args)
            info_dir = args[i + 1]
            i += 2
        else
            push!(remaining, args[i])
            i += 1
        end
    end

    default = normpath(joinpath(@__DIR__, "..", "data", "cmrxrecon2024_map.csv"))
    inpath = length(remaining) >= 1 ? remaining[1] : default
    outpath = length(remaining) >= 2 ? remaining[2] : inpath
    return annotate(inpath, outpath; info_dir = info_dir)
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
