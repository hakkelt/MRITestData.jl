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

    # ── run_browser code path ────────────────────────────────────────────────────
    # app() opens a real terminal and cannot run at precompile time. We cover
    # everything else: model construction, view/update dispatch, and all rendering
    # helpers. This warms the bulk of the latency-sensitive specialisations.

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
    _ = _fmt_sampled(true)
    _ = _fmt_sampled(false)
    _ = _fmt_sampled(nothing)
    _ = _fmt_size(1024)
    _ = _fmt_size(nothing)
    _ = _fmt_sym(:cartesian)
    _ = _fmt_sym(nothing)
end
