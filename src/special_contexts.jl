
#####
##### WithTypeNames
#####

"""
    WithTypeNames(parent_context)

In this hash context, [`StableHashTraits.transform_type`](@ref) returns [`module_nameof_string`](@ref) for
all types, in contrast to the default behavior (which mostly uses
`nameof_string(StructType(T))`).

!!! warn "Unstable"
    `module_nameof_string`'s return value can change with non-breaking
    changes if e.g. the module of a function or type is changed because it's considered an
    implementation detail of a package.

"""
@context WithTypeNames

transform_type(::Type{T}, c::WithTypeNames) where {T} = module_nameof_string(T)

# NOTE: from this point below, only the `transformer` and `type_identifier`-related code is
# new

#####
##### TablesEq
#####

"""
    TablesEq(parent_context)

In this hash context the type and structure of a table do not impact the hash that is
created, only the set of columns (as determined by `Tables.columns`), and the hash of the
individual columns matter.
"""
@context TablesEq

function transformer(::Type{T}, c::TablesEq) where {T}
    Tables.istable(T) && return Transformer(columntable)
    return transformer(T, parent_context(c))
end

"""
    TypeDigestCachedContext(parent::T, ::Type{D}) where {T, D}

A hash context that caches type digests for types seen so far to avoid recomputing them.
"""
struct TypeDigestCachedContext{T, D}
    parent::T
    cache::IdDict{Any, D}
end

TypeDigestCachedContext(parent::T, ::Type{D}) where {T, D} = TypeDigestCachedContext{T, D}(parent, IdDict{Any, D}())

parent_context(c::TypeDigestCachedContext) = c.parent

function type_digest(::Type{T}, hash_state, context::TypeDigestCachedContext) where {T}
    get!(context.cache, T) do
        type_digest(T, hash_state, parent_context(context))
    end
end

TraversalStyle(::Type{<:TypeDigestCachedContext{T}}) where {T} = TraversalStyle(T)

Base.copy(S::TypeDigestCachedContext) = TypeDigestCachedContext(S.parent, copy(S.cache))

function merge_context!(S::TypeDigestCachedContext, other::TypeDigestCachedContext)
    merge!(S.cache, other.cache)
    return S
end

"""
    SymbolStringCachedContext(parent::T) where {T}

A hash context that caches strings for symbols seen so far to avoid recomputing them.
"""
struct SymbolStringCachedContext{T}
    parent::T
    cache::Dict{Symbol, String}
end

SymbolStringCachedContext(parent::T) where {T} = SymbolStringCachedContext{T}(parent, Dict{Symbol, String}())

parent_context(c::SymbolStringCachedContext) = c.parent

function transformer(::Type{Symbol}, context::SymbolStringCachedContext)::Transformer
    return Transformer(hoist_type = true) do x
        return get!(context.cache, x) do
            string(x)
        end
    end
end

TraversalStyle(::Type{<:SymbolStringCachedContext{T}}) where {T} = TraversalStyle(T)

Base.copy(S::SymbolStringCachedContext) = SymbolStringCachedContext(S.parent, copy(S.cache))

function merge_context!(S::SymbolStringCachedContext, other::SymbolStringCachedContext)
    merge!(S.cache, other.cache)
    return S
end