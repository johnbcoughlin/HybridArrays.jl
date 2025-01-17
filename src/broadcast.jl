
import Base.Broadcast: BroadcastStyle
using Base.Broadcast: AbstractArrayStyle, Broadcasted, DefaultArrayStyle

# combine_sizes moved from StaticArrays after https://github.com/JuliaArrays/StaticArrays.jl/pull/1008
# see also https://github.com/JuliaArrays/HybridArrays.jl/issues/50
@generated function combine_sizes(s::Tuple{Vararg{Size}})
    sizes = [sz.parameters[1] for sz ∈ s.parameters]
    ndims = 0
    for i = 1:length(sizes)
        ndims = max(ndims, length(sizes[i]))
    end
    newsize = StaticArrays.StaticDimension[Dynamic() for _ = 1 : ndims]
    for i = 1:length(sizes)
        s = sizes[i]
        for j = 1:length(s)
            if s[j] isa Dynamic
                continue
            elseif newsize[j] isa Dynamic || newsize[j] == 1
                newsize[j] = s[j]
            elseif newsize[j] ≠ s[j] && s[j] ≠ 1
                throw(DimensionMismatch("Tried to broadcast on inputs sized $sizes"))
            end
        end
    end
    quote
        Base.@_inline_meta
        Size($(tuple(newsize...)))
    end
end

function broadcasted_index(oldsize, newindex)
    index = ones(Int, length(oldsize))
    for i = 1:length(oldsize)
        if oldsize[i] != 1
            index[i] = newindex[i]
        end
    end
    return LinearIndices(oldsize)[index...]
end

scalar_getindex(x) = x
scalar_getindex(x::Ref) = x[]

# Add a new BroadcastStyle for StaticArrays, derived from AbstractArrayStyle
# A constructor that changes the style parameter N (array dimension) is also required
struct HybridArrayStyle{N} <: AbstractArrayStyle{N} end
HybridArrayStyle{M}(::Val{N}) where {M,N} = HybridArrayStyle{N}()
BroadcastStyle(::Type{<:HybridArray{<:Tuple, <:Any, N}}) where {N} = HybridArrayStyle{N}()
# Precedence rules
BroadcastStyle(::HybridArray{M}, ::DefaultArrayStyle{N}) where {M,N} =
    DefaultArrayStyle(Val(max(M, N)))
BroadcastStyle(::HybridArray{M}, ::DefaultArrayStyle{0}) where {M} =
    HybridArrayStyle{M}()

BroadcastStyle(::HybridArray{M}, ::StaticArrays.StaticArrayStyle{N}) where {M,N} =
    StaticArrays.Hybrid(Val(max(M, N)))
BroadcastStyle(::HybridArray{M}, ::StaticArrays.StaticArrayStyle{0}) where {M} =
    HybridArrayStyle{M}()

# copy overload
@inline function Base.copy(B::Broadcasted{HybridArrayStyle{M}}) where M
    flat = Broadcast.flatten(B); as = flat.args; f = flat.f
    argsizes = StaticArrays.broadcast_sizes(as...)
    destsize = combine_sizes(argsizes)
    if Length(destsize) === Length{StaticArrays.Dynamic()}()
        # destination dimension cannot be determined statically; fall back to generic broadcast
        return HybridArray{StaticArrays.size_tuple(destsize)}(copy(convert(Broadcasted{DefaultArrayStyle{M}}, B)))
    end
    _broadcast(f, destsize, argsizes, as...)
end
# copyto! overloads
@inline Base.copyto!(dest, B::Broadcasted{<:HybridArrayStyle}) = _copyto!(dest, B)
@inline Base.copyto!(dest::AbstractArray, B::Broadcasted{<:HybridArrayStyle}) = _copyto!(dest, B)
@inline function _copyto!(dest, B::Broadcasted{HybridArrayStyle{M}}) where M
    flat = Broadcast.flatten(B); as = flat.args; f = flat.f
    argsizes = StaticArrays.broadcast_sizes(as...)
    destsize = combine_sizes((Size(dest), argsizes...))
    if Length(destsize) === Length{StaticArrays.Dynamic()}()
        # destination dimension cannot be determined statically; fall back to generic broadcast!
        return copyto!(dest, convert(Broadcasted{DefaultArrayStyle{M}}, B))
    end
    StaticArrays._broadcast!(f, destsize, dest, argsizes, as...)
end


@generated function _broadcast(f, ::Size{newsize}, s::Tuple{Vararg{Size}}, a...) where newsize
    first_staticarray = 0
    for i = 1:length(a)
        if a[i] <: StaticArray
            first_staticarray = a[i]
            break
        end
    end
    if first_staticarray == 0
        for i = 1:length(a)
            if a[i] <: HybridArray
                first_staticarray = a[i]
                break
            end
        end
    end

    exprs = Array{Expr}(undef, newsize)
    more = prod(newsize) > 0
    current_ind = ones(Int, length(newsize))
    sizes = [sz.parameters[1] for sz ∈ s.parameters]

    make_expr(i) = begin
        if !(a[i] <: AbstractArray)
            return :(scalar_getindex(a[$i]))
        elseif hasdynamic(Tuple{sizes[i]...})
            return :(a[$i][$(current_ind...)])
        else
            :(a[$i][$(broadcasted_index(sizes[i], current_ind))])
        end
    end

    while more
        exprs_vals = [make_expr(i) for i = 1:length(sizes)]
        exprs[current_ind...] = :(f($(exprs_vals...)))

        # increment current_ind (maybe use CartesianIndices?)
        current_ind[1] += 1
        for i ∈ 1:length(newsize)
            if current_ind[i] > newsize[i]
                if i == length(newsize)
                    more = false
                    break
                else
                    current_ind[i] = 1
                    current_ind[i+1] += 1
                end
            else
                break
            end
        end
    end

    return quote
        Base.@_inline_meta
        @inbounds elements = tuple($(exprs...))
        @inbounds return similar_type($first_staticarray, eltype(elements), Size(newsize))(elements)
    end
end
