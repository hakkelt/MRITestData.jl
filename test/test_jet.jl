@testitem "JET static analysis" tags = [:quality] begin
    using JET
    using MRITestData

    JET.test_package(MRITestData; target_modules = (MRITestData,))

    @testset "@test_call on public API (offline)" begin
        # Argument-level analysis of the offline catalog/cache surface. These do not
        # hit the network (offline = true) and do not require the extensions.
        @test_call target_modules = (MRITestData,) list_datasets(OCMR_SOURCE; offline = true)
        @test_call target_modules = (MRITestData,) list_datasets(MRIDATA; offline = true)
        @test_call target_modules = (MRITestData,) dataset(OCMR_SOURCE, "fs_0001_1_5T"; offline = true)
        @test_call target_modules = (MRITestData,) index_age_days(OCMR_SOURCE)
    end
end
