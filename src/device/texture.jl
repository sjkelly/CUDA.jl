export CuDeviceTexture

abstract type TextureInterpolationMode end
struct NearestNeighbour      <: TextureInterpolationMode end
struct LinearInterpolation   <: TextureInterpolationMode end
struct CubicInterpolation    <: TextureInterpolationMode end

abstract type TextureMemorySource end
struct ArrayMemory   <: TextureMemorySource end
struct LinearMemory  <: TextureMemorySource end

"""
    CuDeviceTexture{T,N,M,NC,I}

`N`-dimensional device texture with elements of type `T`. This type is the device-side
counterpart of [`CuTexture{T,N,P}`](@ref), and can be used to access textures using regular
indexing notation. If `NC` is true, indices used by these accesses should be normalized,
i.e., fall into the `[0,1)` domain. The `I` type parameter indicates the kind of
interpolation that happens when indexing into this texture. The source memory of the
texture is specified by the `M` parameter, either linear memory or a texture array.

Device-side texture objects cannot be created directly, but should be created host-side
using [`CuTexture{T,N,P}`](@ref) and passed to the kernal as an argument.

!!! warning
    Experimental API. Subject to change without deprecation.
"""
struct CuDeviceTexture{T,N,M<:TextureMemorySource,NC,I<:TextureInterpolationMode} <: AbstractArray{T,N}
    dims::Dims{N}
    handle::CUtexObject
end

Base.convert(::Type{CUtexObject}, t::CuDeviceTexture) = t.handle


## array interface

Base.elsize(::Type{<:CuDeviceTexture{T}}) where {T} = sizeof(T)

Base.size(tm::CuDeviceTexture) = tm.dims
Base.sizeof(tm::CuDeviceTexture) = Base.elsize(x) * length(x)


## low-level operations

# Source: NVVM IR specification 1.4

for dims in 1:3,
    (dispatch_rettyp, julia_rettyp, llvm_rettyp) in
        ((Signed, NTuple{4,UInt32}, :v4u32),
         (Unsigned, NTuple{4,Int32}, :v4s32),
         (AbstractFloat, NTuple{4,Float32},:v4f32)),
    source in (ArrayMemory, LinearMemory)

    eltyp = Union{dispatch_rettyp, NTuple{<:Any,dispatch_rettyp}}

    llvm_dim = "$(dims)d"
    if source == ArrayMemory
        llvm_dim = "$llvm_dim.array"
    end
    julia_args = (:x, :y, :z)[1:dims]
    julia_sig = ntuple(_->Float32, dims)
    julia_params = ntuple(i->:($(julia_args[i])::AbstractFloat), dims)

    @eval tex(texObject::CuDeviceTexture{<:$eltyp,$dims,$source}, $(julia_params...)) =
        ccall($"llvm.nvvm.tex.unified.$llvm_dim.$llvm_rettyp.f32", llvmcall,
            $julia_rettyp, (CUtexObject, $(julia_sig...)), texObject, $(julia_args...))


    # integer indices (tex?Dfetch) requires non-normalized coordinates

    julia_sig = ntuple(_->Int32, dims)
    julia_params = ntuple(i->:($(julia_args[i])::Integer), dims)

    @eval tex(texObject::CuDeviceTexture{<:$eltyp,$dims,$source,false}, $(julia_params...)) =
        ccall($"llvm.nvvm.tex.unified.$llvm_dim.$llvm_rettyp.s32", llvmcall,
            $julia_rettyp, (CUtexObject, $(julia_sig...)), texObject, $(julia_args...))
end


## hardware-supported indexing

@inline function Base.getindex(t::CuDeviceTexture{T,N,<:Any,true,I}, idx::Vararg{<:Real,N}) where
                              {T,N,I<:Union{NearestNeighbour,LinearInterpolation}}
    # normalized coordinates range between 0 and 1, and can be used as-is
    vals = tex(t, idx...)
    return (unpack(T, vals))
end

@inline function Base.getindex(t::CuDeviceTexture{T,N,<:Any,false,I}, idx::Vararg{<:Real,N}) where
                              {T,N,I<:Union{NearestNeighbour,LinearInterpolation}}
    # non-normalized coordinates should be adjusted for 1-based indexing
    vals = tex(t, ntuple(i->idx[i]-1, N)...)
    return (unpack(T, vals))
end

# unpack single-channel texture fetches as values, tuples otherwise
@inline unpack(::Type{T}, vals::NTuple) where T = unpack(T, vals[1])
@inline unpack(::Type{NTuple{1,T}}, vals::NTuple) where T = unpack(T, vals[1])
@inline unpack(::Type{NTuple{C,T}}, vals::NTuple) where {C,T} = ntuple(i->unpack(T, vals[i]), C)

@inline unpack(::Type{T}, val::T) where {T} = val
@inline unpack(::Type{T}, val::Real) where {T <: Integer} = unsafe_trunc(T, val)
@inline unpack(::Type{Float16}, val::Float32) = convert(Float16, val)


## cubic indexing (building on linear filtering)

# Source: GPU Gems 2, Chapter 20: Fast Third-Order Texture Filtering
#         CUDA sample: bicubicTextures

# cubic B-spline basis functions
w0(a::Float32) = (1.0f0/6.0f0)*(a*(a*(-a + 3.0f0) - 3.0f0) + 1.0f0)
w1(a::Float32) = (1.0f0/6.0f0)*(a*a*(3.0f0*a - 6.0f0) + 4.0f0)
w2(a::Float32) = (1.0f0/6.0f0)*(a*(a*(-3.0f0*a + 3.0f0) + 3.0f0) + 1.0f0)
w3(a::Float32) = (1.0f0/6.0f0)*(a*a*a)

# amplitude functions
g0(a::Float32) = w0(a) + w1(a)
g1(a::Float32) = w2(a) + w3(a)

# offset functions
# NOTE: +0.5 offset to compensate for CUDA linear filtering convention
h0(a::Float32) = -1.0f0 + w1(a) / (w0(a) + w1(a)) + 0.5f0
h1(a::Float32) = 1.0f0 + w3(a) / (w2(a) + w3(a)) + 0.5f0

@inline function Base.getindex(t::CuDeviceTexture{T,1,<:Any,false,CubicInterpolation},
                               x::Real) where {T}
    x -= 1.5f0
    px = floor(x)   # integer position
    fx = x - px     # fractional position

    g0x = g0(fx)
    g1x = g1(fx)
    h0x = h0(fx)
    h1x = h1(fx)

    vals = g0x .* tex(t, px + h0x) .+ g1x .* tex(t, px + h1x)
    return (unpack(T, vals))
end

@inline function Base.getindex(t::CuDeviceTexture{T,2,<:Any,false,CubicInterpolation},
                               x::Real, y::Real) where {T}
    x -= 1.5f0
    y -= 1.5f0
    px = floor(x)   # integer position
    py = floor(y)
    fx = x - px     # fractional position
    fy = y - py

    g0x = g0(fx)
    g1x = g1(fx)
    h0x = h0(fx)
    h1x = h1(fx)
    h0y = h0(fy)
    h1y = h1(fy)

    vals = g0(fy) .* (g0x .* tex(t, px + h0x, py + h0y) .+
                      g1x .* tex(t, px + h1x, py + h0y)) .+
           g1(fy) .* (g0x .* tex(t, px + h0x, py + h1y) .+
                      g1x .* tex(t, px + h1x, py + h1y))
    return (unpack(T, vals))
end
