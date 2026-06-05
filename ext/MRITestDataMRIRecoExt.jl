"""
    MRITestDataMRIRecoExt

Package extension loaded when both `MRITestData` and `MRIReco` are present. It
implements `MRITestData.recon(::AcquisitionData; ...)` as a thin, ergonomic wrapper
over `MRIReco.reconstruction(acqData, params)`.

The wrapper just translates keyword arguments into MRIReco's `Symbol`-keyed
parameter `Dict` (merged over `MRIReco.defaultRecoParams()`), so anything
`reconstruction` understands can be passed through. It returns whatever
`reconstruction` returns (an `AxisArray` image).
"""
module MRITestDataMRIRecoExt

using MRITestData: MRITestData
using MRIReco: AcquisitionData, reconstruction, defaultRecoParams

function MRITestData.recon(acq::AcquisitionData; kwargs...)
    params = defaultRecoParams()
    for (k, v) in kwargs
        params[k] = v
    end
    return reconstruction(acq, params)
end

end # module
