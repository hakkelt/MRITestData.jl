"""
    MRITestDataMRTExt

Package extension loaded when both `MRITestData` and `MriReconstructionToolbox`
are present. It provides the real implementation of
`MRITestData.to_acquisition_info`, turning an `acq_spec` `NamedTuple` into a
`MriReconstructionToolbox.AcquisitionInfo`.

Validation (dimension/name checks) is delegated entirely to the toolbox's
`AcquisitionInfo` smart constructor — nothing is duplicated here.
"""
module MRITestDataMRTExt

using MRITestData: MRITestData
using MriReconstructionToolbox: AcquisitionInfo

function MRITestData.to_acquisition_info(spec::NamedTuple)
    if spec.kind === :cartesian
        return AcquisitionInfo(
            spec.kspace_data;
            is3D = spec.is3D,
            image_size = spec.image_size,
            subsampling = spec.subsampling,
        )
    elseif spec.kind === :noncartesian
        return AcquisitionInfo(
            spec.kspace_data;
            trajectory = spec.trajectory,
            dcf = spec.dcf,
            image_size = spec.image_size,
        )
    else
        error("unknown acq_spec kind: $(spec.kind)")
    end
end

end # module
