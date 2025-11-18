module Blake3Ext

using StableHashTraits
using Blake3Hash

function StableHashTraits.update_hash!(ctx::Blake3Ctx, bytes::AbstractVector{UInt8})
    Blake3Hash.update!(ctx, bytes)
    return ctx
end

StableHashTraits.compute_hash!(ctx::Blake3Ctx) = Blake3Hash.digest(ctx)

StableHashTraits.similar_hash_state(::Blake3Ctx) = Blake3Ctx()

end