@testitem "taxonomy: every entry of every source obeys the controlled vocabularies" begin
    using MRITestData

    # The regression net for the committed maps: a typo in a map value would already fail
    # at parse time (DatasetEntry's inner constructor validates), but this test also checks
    # the *live* mridata.org scrape path if it happens to succeed offline (it won't; this
    # runs offline = true everywhere, so only the bundled fallback is exercised).
    for s in list_sources()
        es = list_datasets(s; offline = true)
        for e in es
            @test e.anatomy in ANATOMIES
            @test e.contrast in CONTRASTS
            @test e.trajectory in TRAJECTORIES
            @test e.coil_data in COIL_DATA
            @test e.cardiac_sync in CARDIAC_SYNC
            @test e.acquisition_dim in (1, 2, 3)
            e.echo_type === nothing || @test e.echo_type in ECHO_TYPES
            e.fat_suppression === nothing || @test e.fat_suppression in FAT_SUPPRESSION
            e.cohort === nothing || @test e.cohort in COHORTS
            e.split === nothing || @test e.split in SPLITS
            e.undersampling_pattern === nothing || @test e.undersampling_pattern in UNDERSAMPLING_PATTERNS
            e.orientation === nothing || @test e.orientation in ORIENTATIONS
        end
    end
end

@testitem "taxonomy: DatasetEntry rejects an out-of-vocabulary value" begin
    using MRITestData

    @test_throws ErrorException DatasetEntry(;
        source = OCMR_SOURCE, id = "x", name = "x", url = "", anatomy = :not_a_real_anatomy,
    )
    @test_throws ErrorException DatasetEntry(;
        source = OCMR_SOURCE, id = "x", name = "x", url = "", contrast = :not_a_real_contrast,
    )
    @test_throws ErrorException DatasetEntry(;
        source = OCMR_SOURCE, id = "x", name = "x", url = "", acquisition_dim = 4,
    )
    # A valid entry construts fine.
    @test DatasetEntry(; source = OCMR_SOURCE, id = "x", name = "x", url = "") isa DatasetEntry
end

@testitem "taxonomy: dicom_tag coverage — every core field is anchored or a documented extension" begin
    using MRITestData

    # Fields that are transport/identity, not imaging metadata, and so are neither DICOM-
    # anchored nor a documented "extension" (that list is only for imaging concepts DICOM
    # could plausibly cover but doesn't).
    non_imaging = Set([:source, :id, :approx_size_bytes, :sha256, :url, :extra, :locator])
    for f in fieldnames(DatasetEntry)
        f in non_imaging && continue
        has_tag = dicom_tag(f) !== nothing
        is_extension = haskey(TAXONOMY_EXTENSIONS, f)
        @test has_tag || is_extension
        @test !(has_tag && is_extension)   # never both
    end
end

@testitem "taxonomy: dicom_keyword round-trips through DICOM_ATTRIBUTES" begin
    using MRITestData

    @test dicom_keyword(:field_strength) == "MagneticFieldStrength"
    @test dicom_keyword(:anatomy) == "BodyPartExamined"
    @test dicom_keyword(:receiver_channels) === nothing   # extension, no DICOM tag
    @test dicom_tag(:field_strength) == (0x0018, 0x0087, "MagneticFieldStrength")
end
