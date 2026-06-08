# PrecompileTools workload — exercises call paths that don't require __init__ to
# have run (i.e. no CACHE_DIR, no network). This covers module loading, type
# construction, and the settings layer.
@compile_workload begin
    # Source singletons and their names.
    _ = list_sources()
    _ = source_name(OCMR_SOURCE)
    _ = source_name(MRIDATA)

    # Settings getters — these only read Preferences, no file I/O at precompile time.
    _ = get_chunk_size()
    _ = get_min_file_size()
    _ = get_refresh_period()
    _ = _terms_accepted()
end
