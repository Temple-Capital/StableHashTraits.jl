#####
##### Helper Functions
#####

hash_trait(x::Transformer, y) = x.result_method
hash_trait(::Transformer{<:Any,Nothing}, y) = hash_trait(y)
hash_trait(x) = StructType(x)

"""
    HashRetrievalStrategy

Determine whether we should compute the hash of a value from scratch, or fetch a precomputed
hash value for it. By default, we compute the hash from scratch. If a type provides its own
hash value, it should specialize `HashRetrievalStrategy` to return `FetchHash` and implement `fetch_hash` to return the hash.
In this case, the object identity and its hash would be considered interchangeable for hashing purposes.
"""
abstract type HashRetrievalStrategy end
struct ComputeHash <: HashRetrievalStrategy end
struct FetchHash <: HashRetrievalStrategy end
HashRetrievalStrategy(x::Any) = HashRetrievalStrategy(typeof(x))
HashRetrievalStrategy(::Type) = ComputeHash()

"""
    fetch_hash(x)

Return a precomputed hash value for `x`. This is only called when `HashRetrievalStrategy(x)` returns
`FetchHash`. By default, this function is not implemented, and will throw an error if called.
A type that specializes `HashRetrievalStrategy` to return `FetchHash` must provide its own implementation of this method.
"""
function fetch_hash end

"""
    hash_computed(x)

Indicates whether a precomputed hash value is available for `x`. By default, this returns `false`.
Types that specialize `HashRetrievalStrategy` to return `FetchHash` should also specialize this method to return `true` when the hash is available.

This is mainly useful when the hash must be computed once before being fetched subsequently.

An example of usage:
```julia
mutable struct FieldWithHash
    field
    hash::Union{Nothing, UInt64}
    function FieldWithHash(field)
        x = new(field, nothing)
        x.hash = stable_hash(x, HashVersion{4}())
        return x
    end
end
StableHashTraits.hash_computed(x::FieldWithHash) = !isnothing(x.hash)
StableHashTraits.fetch_hash(x::FieldWithHash) = x.hash
```
"""
hash_computed(x) = false

"""
    @hash_retrieval T field = default [context_type] [hoist_type]

Define methods for types that store a precomputed hash value in a specific field. The macro defines the necessary
specializations of `HashRetrievalStrategy`, `hash_computed`, and `fetch_hash` for type `T`, using the specified
`field` to store the hash value, which defaults to `default` if not computed.

The `context_type` is optional, and is used to specialize the `transformer` method to omit the specified field from hashing.
If `hoist_type` is provided, this is passed on to the `Transformer` constructor to indicate whether the type hash can be hoisted out of loops.

Example:
```julia
mutable struct FieldWithHash
    field
    hash::Union{Nothing, UInt64}
    function FieldWithHash(field)
        x = new(field, nothing)
        x.hash = stable_hash(x, HashVersion{4}())
        return x
    end
end
@hash_retrieval FieldWithHash hash=nothing
```
"""
macro hash_retrieval(T, field_with_default::Expr, context_type=HashVersion{4}, hoist_type::Union{Nothing,Bool}=nothing)
    field_with_default.head == :(=) || error("@hash_field requires a field with a default value provided as `field = default`")
    field, default = field_with_default.args
    default = esc(default)
    T = esc(T)
    field_quote = Expr(:quote, field)
    q = quote
        FT = fieldtype($T, $field_quote)
        $(default) isa FT || throw(ArgumentError("Provided default value is not of the correct type, expected $FT"))
        StableHashTraits.HashRetrievalStrategy(::Type{$T}) = FetchHash()
        StableHashTraits.hash_computed(x::$T) = x.$(field) != $default
        if isnothing($default)
            StableHashTraits.fetch_hash(x::$T) = something(x.$(field))
        else
            StableHashTraits.fetch_hash(x::$T) = x.$(field)
        end
    end
    q = if isnothing(hoist_type)
        quote
            $q
            function StableHashTraits.transformer(::Type{$T}, ::$(esc(context_type)))
                Transformer(omit_fields($field_quote))
            end
        end
    else
        quote
            $q
            function StableHashTraits.transformer(::Type{$T}, ::$(esc(context_type)))
                Transformer(omit_fields($field_quote), hoist_type=$(esc(hoist_type)))
            end
        end
    end
    return q
end

"""
    TraversalStyle(context)

Determine the traversal style to use when hashing objects in the given `context`.
Defaults to `TopDownTraversal`, but can be specialized for specific contexts.
In a `TopDownTraversal`, the type digest of an object is hashed before its value/fields;
in a `BottomUpTraversal`, the type digest is hashed after its value/fields.

Contexts that wrap another context should generally forward to the parent context unless they
specifically want to change the traversal style.
"""
abstract type TraversalStyle end
struct TopDownTraversal <: TraversalStyle end
struct BottomUpTraversal <: TraversalStyle end

TraversalStyle(x::Any) = TraversalStyle(typeof(x))
TraversalStyle(::Type) = TopDownTraversal()

@context BottomUpTraversalContext
TraversalStyle(::Type{<:BottomUpTraversalContext}) = BottomUpTraversal()

# how we hash when we haven't hoisted the type hash out of a loop
function hash_type_and_value(x, hash_state, context)
    hash_type_and_value(HashRetrievalStrategy(x), x, hash_state, context)
end

function hash_type_and_value(::FetchHash, x, hash_state, context)
    if hash_computed(x)
        return update_hash!(hash_state, fetch_hash(x))
    else
        return hash_type_and_value(ComputeHash(), x, hash_state, context)
    end
end

_transformer_typeof(x, context) = transformer(typeof(x), context)
# split these special cases to improe type-stability
_transformer_typeof(::Type, context) = transformer(DataType, context)
_transformer_typeof(::Union, context) = transformer(Union, context)
_transformer_typeof(::UnionAll, context) = transformer(UnionAll, context)
function hash_type_and_value(::ComputeHash, x, hash_state, context)
    transform = _transformer_typeof(x, context)::Transformer
    tx = transform(x)
    hash_type_and_value(TraversalStyle(context), x, hash_state, context, transform, tx)
    return hash_state
end

function hash_type_and_value(::TopDownTraversal, x, hash_state, context, transform::Transformer, tx)
    hash_state = hash_type!(hash_state, context, x, tx, transform.hoist_type)
    hash_state = hash_value(tx, hash_state, context, transform)
    return hash_state
end

function hash_type_and_value(::BottomUpTraversal, x, hash_state, context, transform::Transformer, tx)
    hash_state = hash_value(tx, hash_state, context, transform)
    hash_state = hash_type!(hash_state, context, x, tx, transform.hoist_type)
    return hash_state
end

# how we hash when the type hash can be hoisted out of a loop
function hash_value(tx, hash_state, context, transform::Transformer)
    return stable_hash_helper(tx, hash_state, context, hash_trait(transform, tx))
end

# There are two cases where we want to hash types:
#
#   1. when we are hashing the type of an object we're hashing (`TypeHashContext`)
#   2. when a value we're hashing is itself a type (`TypeAsValueContext`)
#
# These are handled as separate contexts because the kind of value we want to generate from
# the type may differ. By default only the structure of types matters when hashing an
# objects type, e.g. when we hash a StructTypes.DataType we hash that it is a data type, the
# field names and we hash each individual element type (as per its rules) but we do not hash
# the name of the type. When a type is hashed as a value, its actual name also matters.

#####
##### Type Hashes
#####

"""
    type_digest(T, context; alg = sha256)
    type_digest(T, hash_state, context)

Compute the hash digest of type `T` in the given context, and using a similar `hash_state`, if provided.

```jldoctest
julia> StableHashTraits.type_digest(Int64, HashVersion{4}()) |> bytes2hex
"475e60698746bb2903a6d8637a17e6f88ae76d2c93a89eb18d295baf094e7837"
```
"""
type_digest(::Type{T}, context; alg = sha256) where {T} = type_digest(T, HashState(alg, context), context)

function type_digest(::Type{T}, hash_state, context) where {T}
    type_context = TypeHashContext(context)
    transform = transformer(typeof(T), type_context)
    tT = transform(T)
    hash_type_state = similar_hash_state(hash_state)
    hash_type_state = hash_value(tT, hash_type_state, type_context, transform)
    digest = compute_hash!(hash_type_state)
    return digest
end

function hash_type!(hash_state, context, x, tx, hoist_type::Bool)
    hash_state = if hoist_type
        hash_type!(hash_state, context, typeof(x))
    else
        hash_type!(hash_state, context, typeof(tx))
    end
    return hash_state
end

"""
    hash_type!(hash_state, context, T)

Hash type `T` in the given context, updating `hash_state`.
"""
function hash_type!(hash_state, context, ::Type{T}) where {T}
    digest = type_digest(T, hash_state, context)
    bytes = as_hash_compatible_input(digest, hash_state)

    return update_hash!(hash_state, bytes)
end

"""
    as_hash_compatible_input(digest, context; alg = sha256)
    as_hash_compatible_input(digest, hash_state::HashState)

Return a representation of `digest` suitable for passing to `update_hash!` with
`hash_state`. By default, this is a `Vector{UInt8}`. If a context and an algorithm
are provided, a `HashState` is constructed to determine the appropriate representation.
"""
as_hash_compatible_input(digest, context; alg = sha256) = as_hash_compatible_input(digest, HashState(alg, context))
as_hash_compatible_input(digest, hash_state::HashState) = as_bytes_vector(digest)
as_bytes_vector(digest) = copy(reinterpret(UInt8, asarray(digest)))
as_bytes_vector(x::Union{UInt32,UInt64,UInt128}) = collect(reinterpret(NTuple{sizeof(x),UInt8}, x))

asarray(x) = [x]
asarray(x::AbstractArray) = x

@context TypeHashContext
TypeHashContext(x::TypeHashContext) = x
hash_type!(hash_state, ::TypeHashContext, key::Type) = hash_state

# pair_structure: When the internal structure of a type is `nothing`, avoid additional
# tuple-nesting in the returned value to hash. This ensures that if we want two types to
# transform to the same string, the hashed value doesn't depend on how many transformations
# deep we go to "find" this identical string (unless there is distinct structure that *must*
# be hashed give its `StructType`).
pair_structure(x, ::Nothing) = x
pair_structure(x, y) = (x, y)
"""
    isrecursivetype(T)

Indicates whether type `T` is recursive, i.e., its fieldtypes may contain references to `T`.
"""
isrecursivetype(T) = false
function transformer(::Type{T}, context::TypeHashContext) where {T<:Type}
    return Transformer() do T
        transT = transform_type(T, parent_context(context))
        sT = StructType_(T)
        # avoid infinite recursion on recursive structs by skipping the internal structure
        return pair_structure(transT,
                              isrecursivetype(T) ? nothing :
                              internal_type_structure_(T, sT))
    end
end
@inline StructType_(T) = StructType(T)
StructType_(::Type{Union{}}) = StructTypes.NoStructType()
internal_type_structure_(T, trait) = internal_type_structure(T, trait)

function internal_type_structure_(T, c::StructTypes.UnorderedStruct)
    if T === DataType
        return nothing
    else
        internal_type_structure(T, c)
    end
end

# NOTE: `internal_type_structure` implements mandatory elements of a type's structure that
# are always included in the hash; this ensures that the invariants required by type
# hoisting hold
internal_type_structure(T, trait) = nothing

#####
##### Hashing Types as Values
#####

struct TypeAsValue <: StructTypes.StructType end
hash_trait(::Type) = TypeAsValue()

struct TypeAsValueContext{T}
    parent::T
end
parent_context(x::TypeAsValueContext) = x.parent

function hash_type!(hash_state, ::Any, ::Type{<:Type})
    return update_hash!(hash_state, "Base.Type")
end
# these methods are required to avoid method ambiguities
function hash_type!(hash_state, ::TypeHashContext, ::Type{<:Type})
    return update_hash!(hash_state, "Base.Type")
end
function hash_type!(hash_state, ::TypeAsValueContext, ::Type{<:Type})
    return update_hash!(hash_state, "Base.Type")
end

function transformer(::Type{<:Type}, context::TypeAsValueContext)
    return Transformer(T -> pair_structure(transform_type_value(T, context),
                                           internal_type_structure(T, StructType_(T))))
end

hash_type!(hash_state, ::TypeAsValueContext, ::Type) = hash_state
function stable_hash_helper(::Type{T}, hash_state, context, ::TypeAsValue) where {T}
    type_context = TypeAsValueContext(context)
    transform = transformer(typeof(T), type_context)::Transformer
    tT = transform(T)
    return stable_hash_helper(tT, hash_state, type_context, hash_trait(transform, tT))
end

#####
##### Function Hashes
#####

# remember: functions can have fields; in general StructTypes doesn't assume these are
# serialized but here we want that to happen by default, so e.g. ==(2) will properly hash
# both the name of `==` and `2`.
hash_trait(::Function) = StructTypes.UnorderedStruct()

transform_type(::Type{T}) where {T<:Function} = nameof_string(T)

#####
##### DataType
#####

transform_type_by_trait(::Type{T}, ::StructTypes.DataType) where {T} = nameof_string(T)

sorted_field_names(T::Type) = TupleTools.sort(fieldnames(T); by=string)
@generated function sorted_field_names(T)
    return TupleTools.sort(fieldnames(T); by=string)
end

function internal_type_structure(::Type{T}, trait::StructTypes.DataType) where {T}
    if isconcretetype(T)
        fields = trait isa StructTypes.OrderedStruct ? fieldnames(T) : sorted_field_names(T)
        return fields, map(field -> fieldtype(T, field), fields)
    else
        return nothing
    end
end

function stable_hash_helper_nested(f!, hash_state)
    nested_hash_state = start_nested_hash!(hash_state)
    nested_hash_state = f!(nested_hash_state)
    hash_state = end_nested_hash!(hash_state, nested_hash_state)
    return hash_state
end

function stable_hash_helper(x, hash_state, context, st::StructTypes.DataType)
    return stable_hash_helper_nested(hash_state) do nested_hash_state
        # hash the field values
        fields = st isa StructTypes.UnorderedStruct ? sorted_field_names(x) :
                fieldnames(typeof(x))
        hash_fields(x, fields, nested_hash_state, context)
    end
end

Base.@constprop :aggressive function hash_fields(x, fields, hash_state, context)
    vals = map(field -> getfield(x, field), fields)
    map(fields, vals) do field, val
        # can we optimize away the field's type_hash?
        transform = transformer(typeof(val), context)
        FT = fieldtype(typeof(x), field)
        if isconcretetype(FT) && transform.hoist_type && HashRetrievalStrategy(FT) !== FetchHash()
            # the fieldtype has been hashed as part of the type of the container
            hash_value(transform(val), hash_state, context, transform)
        else
            hash_type_and_value(val, hash_state, context)
        end
    end
    return hash_state
end

#####
##### ArrayType
#####

"""
    is_ordered(x)

Indicates whether the order of the elements of object `x` are important to its hashed value.
If false, `x`'s elements will first be `collect`ed and `sort`'ed before hashing them. When
calling `sort`, [`hash_sort_by`](@ref) is passed as the `by` keyword argument.
If `x` is a `DictType`, the elements are sorted by their keys rather than their elements.
"""
is_ordered(x) = true
is_ordered(::AbstractSet) = false

"""
    `hash_sort_by(x)`

Defines how the elements of a hashed container `x` are `sort`ed if [`is_ordered`](@ref) of
`x` returns `false`. The return value of this function is passed to `sort` as the `by`
keyword.
"""
hash_sort_by(x::Symbol) = String(x)
hash_sort_by(x::Char) = string(x)
hash_sort_by(x) = x

function internal_type_structure(::Type{T}, ::StructTypes.ArrayType) where {T}
    return eltype(T)
end

# include ndims in type hash when we can
function transform_type(::Type{T}) where {T<:AbstractArray}
    return transform_type_by_trait(T, StructType(T)), ndims_(T)
end
function transform_type_value(::Type{T}) where {T<:AbstractArray}
    return nameof_string(T), ndims_(T)
end
ndims_(::Type{<:AbstractArray{<:Any,N}}) where {N} = N
ndims_(::Type{<:AbstractArray}) = nothing

function transformer(::Type{<:AbstractArray}, ::HashVersion{4})
    return Transformer(x -> (size(x), split_union(x)); hoist_type=true)
end

split_union(array) = TransformIdentity(array)
# NOTE: this method actually properly handles union splitting for as many splits as julia
# will allow to match to this method, not just two; in the case where the eltype is
# Union{Int, UInt, Char} for instance, M will match to Union{UInt, Char} and the `else`
# branch will properly split out the first type. The returned M_array will then be split
# again, when the `transformer` method above is applied to it.
function split_union(array::AbstractArray{Union{N,M}}) where {N,M}
    # NOTE: when an abstract array is e.g. AbstractArray{Int}, N becomes
    # Int and M is left as undefined, we just need to hash this array
    if !(eltype(array) isa Union)
        return TransformIdentity(array)
    end
    # special case null and singleton-types, since we don't need to hash their content at
    # all
    if StructType(N) isa StructTypes.NullType ||
       StructType(N) isa StructTypes.SingletonType
        isM_array = isa.(array, M)
        return isM_array, convert(AbstractArray{M}, array[isM_array])
    elseif StructType(M) isa StructTypes.NullType ||
           StructType(M) isa StructTypes.SingletonType
        # I'm not actually sure if its possible to hit this `elseif` branch since "smaller"
        # types seem to occur first in the `Union`, but its here since I don't know that
        # this pattern is documented behavior or an implementation detail of the current
        # version of julia, nor do I know if all singleton-types count as smaller than
        # non-singleton types
        isN_array = isa.(array, N)
        return isN_array, convert(AbstractArray{N}, array[isN_array])
    else
        isN_array = isa.(array, N)
        N_array = convert(AbstractArray{N}, array[isN_array])
        M_array = convert(AbstractArray{M}, array[.!isN_array])
        return isN_array, N_array, M_array
    end
end

function stable_hash_helper(xs, hash_state, context, ::StructTypes.ArrayType)
    return stable_hash_helper_nested(hash_state) do nested_hash_state
        items = !is_ordered(xs) ? sort!(collect(xs); by=hash_sort_by) : xs
        transform = transformer(eltype(items), context)::Transformer
        hash_elements(items, nested_hash_state, context, transform)
    end
end

abstract type HashElementsStrategy end
struct HashAllElements <: HashElementsStrategy end
struct HashSelectedElements <: HashElementsStrategy end
HashElementsStrategy(context) = HashElementsStrategy(typeof(context))
HashElementsStrategy(::Type) = HashAllElements()

function _hash_elements(items, hash_state, context, transform, ::HashAllElements)
    # can we optimize away the element type hash?
    # We skip this if the elements store their own hash, as the type of each elements has already been hashed
    type_hoist = isconcretetype(eltype(items)) && transform.hoist_type && HashRetrievalStrategy(eltype(items)) !== FetchHash()
    if type_hoist
        # the eltype has already been hashed as part of the type structure of
        # the container
        for x in items
            hash_value(transform(x), hash_state, context, transform)
        end
    else
        for x in items
            hash_type_and_value(x, hash_state, context)
        end
    end
    return hash_state
end

# The following are adapted from Julia Base
#=
Copyright (c) 2009 Jeff Bezanson

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright notice,
      this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice,
      this list of conditions and the following disclaimer in the documentation
      and/or other materials provided with the distribution.
    * Neither the author nor the names of any contributors may be used to
      endorse or promote products derived from this software without specific
      prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
=#

function hash_shaped(f, A, hash_state, context, transform)
    len = length(A)

    if len < 32768
        for elt in A
            hash_state = f(elt, hash_state, context, transform)
        end
    else
        hash_state = _hash_fib(f, A, hash_state, context, transform)
    end
    return hash_state
end

function _hash_fib(f, A, hash_state, context, transform)
    # Goal: Hash approximately log(N) entries with a higher density of hashed elements
    # weighted towards the end and special consideration for repeated values. Colliding
    # hashes will often subsequently be compared by equality -- and equality between arrays
    # works elementwise forwards and is short-circuiting. This means that a collision
    # between arrays that differ by elements at the beginning is cheaper than one where the
    # difference is towards the end. Furthermore, choosing `log(N)` arbitrary entries from a
    # sparse array will likely only choose the same element repeatedly (zero in this case).

    # To achieve this, we work backwards, starting by hashing the last element of the
    # array. After hashing each element, we skip `fibskip` elements, where `fibskip`
    # is pulled from the Fibonacci sequence -- Fibonacci was chosen as a simple
    # ~O(log(N)) algorithm that ensures we don't hit a common divisor of a dimension
    # and only end up hashing one slice of the array (as might happen with powers of
    # two). Finally, we find the next distinct value from the one we just hashed.

    # This is a little tricky since skipping an integer number of values inherently works
    # with linear indices, but `findprev` uses `keys`. Hoist out the conversion "maps":
    ks = keys(A)
    key_to_linear = LinearIndices(ks) # Index into this map to compute the linear index
    linear_to_key = vec(ks)           # And vice-versa

    # Start at the last index
    keyidx = last(ks)
    linidx = key_to_linear[keyidx]
    fibskip = prevfibskip = oneunit(linidx)
    first_linear = first(LinearIndices(linear_to_key))

    n = 0
    while true
        n += 1
        # Hash the element
        elt = A[keyidx]

        # convert to a key-value pair if the transform is compatible, otherwise hash the element and hope for the best
        eltp = transform isa Transformer{typeof(identity),Nothing} ? (keyidx=>elt) : elt
        hash_state = f(eltp, hash_state, context, transform)

        # Skip backwards a Fibonacci number of indices -- this is a linear index operation
        linidx = key_to_linear[keyidx]
        linidx < fibskip + first_linear && break
        linidx -= fibskip
        keyidx = linear_to_key[linidx]

        # Only increase the Fibonacci skip once every N iterations. This was chosen
        # to be big enough that all elements of small arrays get hashed while
        # obscenely large arrays are still tractable. With a choice of N=4096, an
        # entirely-distinct 8000-element array will have ~75% of its elements hashed,
        # with every other element hashed in the first half of the array. At the same
        # time, hashing a `typemax(Int64)`-length Float64 range takes about a second.
        if rem(n, 4096) == 0
            fibskip, prevfibskip = fibskip + prevfibskip, fibskip
        end

        # Find a key index with a value distinct from `elt` -- might be `keyidx` itself
        keyidx = findprev(!isequal(elt), A, keyidx)
        keyidx === nothing && break
    end

    return hash_state
end

function _hash_elements(items, hash_state, context, transform, ::HashSelectedElements)
    # can we optimize away the element type hash?
    # We skip this if the elements store their own hash, as the type of each elements has already been hashed
    type_hoist = isconcretetype(eltype(items)) && transform.hoist_type && HashRetrievalStrategy(eltype(items)) !== FetchHash()
    if type_hoist
        # the eltype has already been hashed as part of the type structure of
        # the container
        @inline hash_value_helper(x, hash_state, context, transform) = hash_value(transform(x), hash_state, context, transform)
        hash_shaped(hash_value_helper, items, hash_state, context, transform)
    else
        @inline hash_type_and_value_helper(x, hash_state, context, transform) = hash_type_and_value(x, hash_state, context)
        hash_shaped(hash_type_and_value_helper, items, hash_state, context, transform)
    end
    return hash_state
end

function hash_elements(items, hash_state, context, transform)
    _hash_elements(items, hash_state, context, transform, HashElementsStrategy(context))
end

#####
##### AbstractRange
#####

transform_type(::Type{<:AbstractRange}) = "Base.AbstractRange"
function transformer(::Type{<:AbstractRange}, ::HashVersion{4})
    return Transformer(x -> (first(x), step(x), last(x)); hoist_type=true)
end

#####
##### Tuples
#####

function internal_type_structure(::Type{T}, ::StructTypes.ArrayType) where {T<:Tuple}
    if isconcretetype(T)
        fields = T <: StructTypes.OrderedStruct ? fieldnames(T) : sorted_field_names(T)
        return fields, map(field -> fieldtype(T, field), fields)
    else
        return nothing
    end
end

function internal_type_structure(::Type{T}, ::StructTypes.ArrayType) where {T<:NTuple}
    return eltype(T)
end

function stable_hash_helper(x::Tuple, hash_state, context, ::StructTypes.ArrayType)
    return stable_hash_helper_nested(hash_state) do nested_hash_state
        nested_hash_state = hash_fields(x, fieldnames(typeof(x)), nested_hash_state, context)
    end
end

#####
##### DictType
#####

is_ordered(x::AbstractDict) = false

_internal_type_structure(::Any) = nothing
_internal_type_structure(::Type{<:AbstractDict{K}}) where {K} = (K, Any)
_internal_type_structure(::Type{<:AbstractDict{<:Any,V}}) where {V} = (Any, V)
_internal_type_structure(::Type{<:AbstractDict{K,V}}) where {K,V} = (K, V)
_internal_type_structure(::Type{<:Pair{K}}) where {K} = (K, Any)
_internal_type_structure(::Type{<:Pair{<:Any,V}}) where {V} = (Any, V)
_internal_type_structure(::Type{<:Pair{K,V}}) where {K,V} = (K, V)

function internal_type_structure(::Type{T}, ::StructTypes.DictType) where {T}
    isconcretetype(T) || return _internal_type_structure(T)
    return keytype(T), valtype(T)
end

# `Pair` does not implement `keytype` or `valtype`
function internal_type_structure(::Type{<:Pair{K,V}}, ::StructTypes.DictType) where {K,V}
    return K, V
end

hash_trait(::Pair) = StructTypes.OrderedStruct()

function stable_hash_helper(x, hash_state, context, ::StructTypes.DictType)
    return stable_hash_helper_nested(hash_state) do nested_hash_state
        pairs = StructTypes.keyvaluepairs(x)

        pairs = if is_ordered(x)
            StructTypes.keyvaluepairs(x)
        else
            sort!(collect(StructTypes.keyvaluepairs(x)); by=hash_sort_by ∘ first)
        end
        transform = transformer(eltype(x), context)::Transformer
        hash_elements(pairs, nested_hash_state, context, transform)
    end
end

#####
##### CustomStruct
#####

# we need to hash the type for every instance when we have a CustomStruct; `lowered` could
# be anything
function stable_hash_helper(x, hash_state, context, ::StructTypes.CustomStruct)
    return hash_type_and_value(StructTypes.lower(x), hash_state, context)
end

#####
##### Basic data types
#####

transform_type(::Type{Symbol}) = "Base.Symbol"
function transformer(::Type{<:Symbol}, ::HashVersion{4})
    return Transformer(String; hoist_type=true)
end

function transformer(::Type{<:Union{BigInt, BigFloat}}, ::HashVersion{4})
    return Transformer(string; hoist_type=true)
end

function stable_hash_helper(str, hash_state, context, ::StructTypes.StringType)
    return stable_hash_helper_nested(hash_state) do nested_hash_state
        update_hash!(nested_hash_state, str isa AbstractString ? str : string(str))
    end
end

function stable_hash_helper(number::T, hash_state, context,
                            ::StructTypes.NumberType) where {T}
    U = StructTypes.numbertype(T)
    return update_hash!(hash_state, U(number))
end

function stable_hash_helper(bool, hash_state, context, ::StructTypes.BoolType)
    return update_hash!(hash_state, Bool(bool))
end

# null types are encoded purely by their type hash
transform_type(::Type{Missing}) = "Base.Missing"
transform_type(::Type{Nothing}) = "Base.Nothing"
transform_type_by_trait(::Type{T}, ::StructTypes.NullType) where {T} = nameof_string(T)
stable_hash_helper(_, hash_state, context, ::StructTypes.NullType) = hash_state

# singleton types are encoded purely by their type hash
transform_type_by_trait(::Type{T}, ::StructTypes.SingletonType) where {T} = nameof_string(T)
stable_hash_helper(_, hash_state, context, ::StructTypes.SingletonType) = hash_state

#####
##### Regex
#####

# NOTE: we don't have great options for keeping the next few functions from depending on
# some internals of Base julia
#
# The underlying problem is that there is no public API for inspecting regex flags or the
# regex pattern of a regex.
#
# We can:
#
# 1. Use the string representation of regex: non-breaking Julia releases change this
# 2. Directly read private fields of Regex and use flag defaults to compute what relevant
#    regex flags have been marked (e.g. `r"a"i` has the `i` flag marked).
#
# An added complication is that the default options for PCRE change across Julia versions,
# so we can't just use all the bytes of `compile_options`; this will break compatibility
# across julia versions.
#
# It seems more likely that the string representation will change than that the fields and
# private bit masks will change; so for now, the second approach is taken.

pattern_(x::Regex)::String = x.pattern

function compile_options_(x::Regex)::UInt32
    # NOTE: using this mask kept the code from breaking on Julia 1.6 we can't change it now,
    # since we don't want the hash to change furthermore, the default flags could
    # conceivably change in a future julia version. In our tests, we verify that this mask
    # properly captures the state all documented regex flags.
    mask = ~Base.DEFAULT_COMPILER_OPTS | Base.PCRE.UCP
    return x.compile_options & mask
end

# NOTE: we can safely hoist here because
# 1. the input type is concrete
# 2. all output types are primitive, concrete types
function transformer(::Type{Regex}, ::HashVersion{4})
    # This skips the compiled regex which is stored as a Ptr{Nothing}
    return Transformer(x -> (pattern_(x), compile_options_(x)); hoist_type=true)
end
