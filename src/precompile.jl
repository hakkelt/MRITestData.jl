# PrecompileTools workload — exercises call paths that don't require __init__ to
# have run (i.e. no CACHE_DIR, no network). This covers module loading, type
# construction, and the settings layer.
@compile_workload begin
    # Source singletons and their names.
    _ = list_sources()
    _ = source_name(OCMR_SOURCE)
    _ = source_name(MRIDATA)
    _ = terms_url(OCMR_SOURCE)
    _ = terms_url(MRIDATA)

    # Settings getters — these only read Preferences, no file I/O at precompile time.
    _ = get_chunk_size()
    _ = get_min_file_size()
    _ = get_refresh_period()
    _ = _terms_accepted()

    # ── Catalog parsing from bundled files ───────────────────────────────────────
    # run_browser calls query() which parses the bundled TOML/CSV at first use.
    # We call the internal parsers directly here (bypassing ensure_index, which
    # needs CACHE_DIR) so that the DatasetEntry kwcall specializations for every
    # field-type combination that occurs in real data are precompiled and cached.
    _ = [_mridata_entry(d) for d in _mridata_raw(_BUNDLED_MRIDATA_INDEX)]
    let _pc_data, _pc_header
        _pc_data, _pc_header = readdlm(_BUNDLED_OCMR_CSV, ','; header = true)
        _pc_col = Dict(strip(String(h)) => i for (i, h) in enumerate(vec(_pc_header)))
        for _pc_r in axes(_pc_data, 1)
            _ocmr_entry(_pc_data[_pc_r, :], _pc_col)
        end
    end
    # CMRxRecon2024 offset-map parser (bypassing ensure_index, which needs CACHE_DIR).
    _ = _cmrxrecon_entries(_CMRXRECON_MAP_PATH)

    # CMRxRecon2024 .mat→ISMRMRD conversion + load (synthetic; no network/CACHE_DIR).
    let
        _pc_k = ComplexF32.(reshape(1:(6 * 4 * 2 * 1 * 2), 6, 4, 2, 1, 2))
        _pc_mask = falses(6, 4, 2)
        _pc_mask[:, [1, 3], 1] .= true
        _pc_mask[:, [2, 4], 2] .= true
        _pc_h5 = tempname() * ".h5"
        try
            _cmrxrecon_to_ismrmrd(_pc_k, _pc_mask, _pc_h5)
            load_raw(_pc_h5)
        finally
            isfile(_pc_h5) && rm(_pc_h5; force = true)
            isfile(_pc_h5 * ".part") && rm(_pc_h5 * ".part"; force = true)
        end
    end

    # ── run_browser code path ────────────────────────────────────────────────────
    # app() opens a real terminal and cannot run at precompile time. record_app()
    # runs the same model+view+update! loop headlessly (no TTY, no raw mode) and
    # exercises the Base.invokelatest dispatch paths that app() uses internally —
    # the key gap that the direct view()/update!() calls below cannot reach.

    # Minimal synthetic entries — two rows so sorting/filtering paths are exercised.
    _pc_entries = DatasetEntry[
        DatasetEntry(;
            source = OCMR_SOURCE,
            id = "pc_entry_1",
            name = "Precompile Entry 1",
            anatomy = :cardiac,
            field_strength = 3.0,
            trajectory = :cartesian,
            coils = 18,
            fully_sampled = true,
            url = "https://example.com/pc1.h5",
        ),
        DatasetEntry(;
            source = MRIDATA,
            id = "pc_entry_2",
            name = "Precompile Entry 2",
            anatomy = :knee,
            field_strength = 1.5,
            trajectory = :radial,
            coils = 8,
            fully_sampled = false,
            approx_size_bytes = 1024,
            url = "https://example.com/pc2.h5",
        ),
    ]

    # BrowserModel construction (covers _build_provider → InMemoryPagedProvider,
    # PagedDataTable, TaskQueue, TextInput).
    _pc_model = BrowserModel(_pc_entries)

    # Run a two-frame headless app loop via record_app. This exercises the
    # Base.invokelatest paths inside the Tachikoma event loop (view, pre_render!,
    # update!, should_quit, task_queue) that direct method calls cannot reach.
    # A quit KeyEvent on frame 1 stops the loop immediately after one render.
    _pc_tach = tempname() * ".tach"
    try
        record_app(
            BrowserModel(_pc_entries),
            _pc_tach;
            width = 120,
            height = 40,
            frames = 2,
            fps = 30,
            events = [(1, KeyEvent('q'))],
        )
    finally
        isfile(_pc_tach) && rm(_pc_tach)
    end

    # view() — covers render(pdt, …), render(_HELP_BAR, …), and the Tachikoma
    # Buffer/Rect machinery for the full browse layout.
    _pc_buf = Buffer(Rect(1, 1, 120, 40))
    _pc_frame = Frame(_pc_buf, Rect(1, 1, 120, 40), GraphicsRegion[], PixelSnapshot[])
    view(_pc_model, _pc_frame)

    # update! — :browse stage key events (delegates to PagedDataTable).
    # :enter is intentionally excluded — it calls cache_path which needs CACHE_DIR
    # initialised by __init__ and is not safe to invoke at precompile time.
    for _pc_key in [:up, :down, :pageup, :pagedown, :home, :end_key, :escape]
        update!(_pc_model, KeyEvent(_pc_key))
    end
    update!(_pc_model, KeyEvent('q'))
    update!(_pc_model, KeyEvent('/'))
    update!(_pc_model, KeyEvent('f'))

    # mouse event dispatch (:browse stage)
    update!(_pc_model, MouseEvent(10, 5, mouse_left, mouse_press, false, false, false))

    # :confirm stage — set selected and render the confirmation overlay.
    _pc_model.selected = _pc_entries[1]
    _pc_model.stage = :confirm
    view(_pc_model, _pc_frame)
    for _pc_ch in ['y', 'n', 'Y', 'N', 'q']
        update!(_pc_model, KeyEvent(_pc_ch))
        _pc_model.quit = false
        _pc_model.stage = :confirm
    end
    update!(_pc_model, KeyEvent(:escape))

    # :token stage — render the Synapse PAT overlay and exercise typing + escape.
    # :enter is excluded — it calls set_synapse_token! which writes a preference file.
    _pc_model.stage = :token
    _pc_model.selected = _pc_entries[1]
    view(_pc_model, _pc_frame)
    update!(_pc_model, KeyEvent('x'))
    update!(_pc_model, KeyEvent(:escape))

    # :path stage — render path input overlay and test escape.
    # :enter is excluded — with an empty path input it falls back to cache_path
    # which needs CACHE_DIR initialised by __init__.
    _pc_model.stage = :path
    _pc_model.selected = _pc_entries[1]
    view(_pc_model, _pc_frame)
    update!(_pc_model, KeyEvent(:escape))

    # TaskEvent fallback handler (no-op path).
    _pc_model.quit = false
    _pc_model.stage = :browse
    update!(_pc_model, TaskEvent(:other, nothing))

    # Size-prefetch TaskEvent (the typed path used by _fire_prefetch!).
    update!(
        _pc_model,
        TaskEvent(:size_prefetch, (0, Int[1], Dict{String, Int}("pc_entry_1" => 512))),
    )

    # Helper formatting used in _entry_row / _COLUMNS format callbacks.
    _ = _fmt_b0(3.0)
    _ = _fmt_b0(nothing)
    _ = _fmt_coils(18)
    _ = _fmt_coils(nothing)
    _ = _fmt_coils("multi")
    _ = _fmt_sampling(true)
    _ = _fmt_sampling(false)
    _ = _fmt_sampling(nothing)
    _ = _fmt_sampling("pseudo-random")
    _ = _fmt_size(1024)
    _ = _fmt_size(nothing)
    _ = _fmt_sym(:cartesian)
    _ = _fmt_sym(nothing)
end
