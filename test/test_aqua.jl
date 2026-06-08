@testitem "Aqua" tags = [:quality] begin
    using Aqua
    using MRITestData

    # `persistent_tasks` is disabled: it resolves the package in a fresh subprocess
    # from registries, which cannot work in this dev setup where MRIBase/MRIFiles
    # are unregistered local checkouts. It is not a code-quality signal here.
    Aqua.test_all(MRITestData; persistent_tasks = false)
end
