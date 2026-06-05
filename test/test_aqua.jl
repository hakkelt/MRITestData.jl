@testitem "Aqua" tags = [:quality] begin
    using Aqua
    using MRITestData

    # `recon` and `to_acquisition_info` are deliberately defined in the main module
    # and extended in the package extensions, so the ambiguity/piracy checks see the
    # base methods as the owners — no piracy.
    #
    # `persistent_tasks` is disabled: it resolves the package in a fresh subprocess
    # from registries, which cannot work in this dev setup where MRIBase/MRIFiles/
    # MRIReco are unregistered local checkouts. It is not a code-quality signal here.
    Aqua.test_all(MRITestData; persistent_tasks = false)
end
