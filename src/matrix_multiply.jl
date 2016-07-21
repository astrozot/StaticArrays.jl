import Base: *,        Ac_mul_B,  A_mul_Bc,  Ac_mul_Bc,  At_mul_B,  A_mul_Bt,  At_mul_Bt
import Base: A_mul_B!, Ac_mul_B!, A_mul_Bc!, Ac_mul_Bc!, At_mul_B!, A_mul_Bt!, At_mul_Bt!

typealias BlasEltypes Union{Float64, Float32, Complex{Float64}, Complex{Float32}}

# TODO size-inferrable products with AbstractArray (such as StaticMatrix * AbstractVector)
# TODO Potentially a loop version for rather large arrays? Or try and figure out inference problems?


# TODO make faster versions of A*_mul_B*
@generated function A_mul_Bc(A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A * ctranspose(B)
    end
end
@generated function Ac_mul_B(A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        ctranspose(A) * B
    end
end
@generated function Ac_mul_Bc(A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        ctranspose(B*A) # is this always safe?
    end
end

@generated function A_mul_Bt(A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A * transpose(B)
    end
end
@generated function At_mul_B(A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        transpose(A) * B
    end
end
@generated function At_mul_Bt(A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        transpose(B*A) # is this always safe?
    end
end

# mutating

@generated function A_mul_Bc!(C::Union{StaticMatrix, StaticVector}, A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A_mul_B!(C, A, ctranspose(B))
    end
end
@generated function Ac_mul_B!(C::Union{StaticMatrix, StaticVector}, A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A_mul_B!(C, ctranspose(A), B)
    end
end
@generated function Ac_mul_Bc!(C::Union{StaticMatrix, StaticVector}, A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A_mul_B!(C, ctranspose(A), ctranspose(B))
    end
end

@generated function A_mul_Bt!(C::Union{StaticMatrix, StaticVector}, A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A_mul_B!(C, A, transpose(B))
    end
end
@generated function At_mul_B!(C::Union{StaticMatrix, StaticVector}, A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A_mul_B!(C, transpose(A), B)
    end
end
@generated function At_mul_Bt!(C::Union{StaticMatrix, StaticVector}, A::Union{StaticMatrix, StaticVector}, B::Union{StaticMatrix, StaticVector})
    return quote
        $(Expr(:meta, :inline))
        A_mul_B!(C, transpose(A), transpose(B))
    end
end


@generated function *(A::StaticMatrix, b::StaticVector)
    TA = eltype(A)
    Tb = eltype(b)
    sA = size(A)
    sb = size(b)

    s = (sA[1],)
    T = promote_type(TA, Tb)

    if sb[1] != sA[2]
        error("Dimension mismatch")
    end

    if s == sb
        if T == Tb
            newtype = b
        else
            newtype = similar_type(b, T)
        end
    else
        if T == Tb
            newtype = similar_type(b, s)
        else
            newtype = similar_type(b, T, s)
        end
    end

    exprs = [reduce((ex1,ex2) -> :(+($ex1,$ex2)), [:(A[$k, $j]*b[$j]) for j = 1:sA[2]]) for k = 1:sA[1]]

    return quote
        $(Expr(:meta,:inline))
        @inbounds return $(Expr(:call, newtype, Expr(:tuple, exprs...)))
    end
end

#@inline *{S1,S2,S3}(A::MMatrix{S1,S2}, B::MMatrix{S2,S3}) = MMatrix{S1,S3}(SMatrix{S1,S2}(A)*SMatrix{S2,S3}(B))

@generated function *(A::StaticMatrix, B::StaticMatrix)
    TA = eltype(A)
    TB = eltype(B)

    T = promote_type(TA, TB)

    can_mutate = !isbits(A) || !isbits(B) # !isbits implies can get a persistent pointer (to pass to BLAS). Probably will change to !isimmutable in a future version of Julia.
    can_blas = T == TA && T == TB && T <: Union{Float64, Float32, Complex{Float64}, Complex{Float32}}

    if can_mutate
        sA = size(A)
        sB = size(B)
        s = (sA[1], sB[2])

        # Heuristic choice between BLAS and explicit unrolling (or chunk-based unrolling)
        if can_blas && size(A,1)*size(A,2)*size(B,2) >= 14*14*14
            return quote
                $(Expr(:meta, :inline))
                C = similar(A, $T, $s)
                A_mul_B_blas!(C, A, B)
                return C
            end
        elseif size(A,1)*size(A,2)*size(B,2) < 8*8*8
            return quote
                $(Expr(:meta, :inline))
                return A_mul_B_unrolled(A, B)
            end
        else
            return quote
                $(Expr(:meta, :inline))
                return $(similar_type(A, T, s))(A_mul_B_unrolled_chunks(A, B))
            end
        end
    else # both are isbits type...
        # Heuristic choice for amount of codegen
        if size(A,1)*size(A,2)*size(B,2) <= 8*8*8
            return quote
                $(Expr(:meta, :inline))
                return A_mul_B_unrolled(A, B)
            end
        else
            return quote
                $(Expr(:meta, :inline))
                return A_mul_B_unrolled_chunks(A, B)
            end
        end
    end
end

@generated function A_mul_B_unrolled(A::StaticMatrix, B::StaticMatrix)
    sA = size(A)
    sB = size(B)
    TA = eltype(A)
    TB = eltype(B)

    s = (sA[1], sB[2])
    T = promote_type(TA, TB)

    if sB[1] != sA[2]
        error("Dimension mismatch")
    end

    # TODO think about which to be similar to
    if s == sB
        if T == TB
            newtype = B
        else
            newtype = similar_type(B, T)
        end
    else
        if T == TB
            newtype = similar_type(B, s)
        else
            newtype = similar_type(B, T, s)
        end
    end

    exprs = [reduce((ex1,ex2) -> :(+($ex1,$ex2)), [:(A[$(sub2ind(sA, k1, j))]*B[$(sub2ind(sB, j, k2))]) for j = 1:sA[2]]) for k1 = 1:sA[1], k2 = 1:sB[2]]

    return quote
        $(Expr(:meta,:inline))
        @inbounds return $(Expr(:call, newtype, Expr(:tuple, exprs...)))
    end
end

# Concatenate a series of matrix-vector multiplications
# Each function is N^2 not N^3 - aids in compile time.
@generated function A_mul_B_unrolled_chunks(A::StaticMatrix, B::StaticMatrix)
    sA = size(A)
    sB = size(B)
    TA = eltype(A)
    TB = eltype(B)

    s = (sA[1], sB[2])
    T = promote_type(TA, TB)

    if sB[1] != sA[2]
        error("Dimension mismatch")
    end

    # TODO think about which to be similar to
    if s == sB
        if T == TB
            newtype = B
        else
            newtype = similar_type(B, T)
        end
    else
        if T == TB
            newtype = similar_type(B, s)
        else
            newtype = similar_type(B, T, s)
        end
    end

    #vect_exprs = [:($(Symbol("tmp_$k2")) = partly_unrolled_multiply(A, B[:, $k2])) for k2 = 1:sB[2]]

    # Do a custom B[:, k2] to return a SVector (an isbits type) rather than (possibly) a mutable type. Avoids allocation == faster
    tmp_type_in = SVector{sB[1], T}
    tmp_type_out = SVector{sA[1], T}
    vect_exprs = [:($(Symbol("tmp_$k2"))::$tmp_type_out = partly_unrolled_multiply(A, $(Expr(:call, tmp_type_in, [Expr(:ref, :B, sub2ind(s, i, k2)) for i = 1:sB[1]]...)))::$tmp_type_out) for k2 = 1:sB[2]]

    exprs = [:($(Symbol("tmp_$k2"))[$k1]) for k1 = 1:sA[1], k2 = 1:sB[2]]

    return Expr(:block,
        Expr(:meta,:inline),
        vect_exprs...,
        :(@inbounds return $(Expr(:call, newtype, Expr(:tuple, exprs...))))
    )
end

@generated function partly_unrolled_multiply(A::StaticMatrix, b::StaticVector)
    TA = eltype(A)
    Tb = eltype(b)
    sA = size(A)
    sb = size(b)

    s = (sA[1],)
    T = promote_type(TA, Tb)

    if sb[1] != sA[2]
        error("Dimension mismatch")
    end

    if s == sb
        if T == Tb
            newtype = b
        else
            newtype = similar_type(b, T)
        end
    else
        if T == Tb
            newtype = similar_type(b, s)
        else
            newtype = similar_type(b, T, s)
        end
    end

    exprs = [reduce((ex1,ex2) -> :(+($ex1,$ex2)), [:(A[$k, $j]*b[$j]) for j = 1:sA[2]]) for k = 1:sA[1]]

    return quote
        $(Expr(:meta,:noinline))
        @inbounds return $(Expr(:call, newtype, Expr(:tuple, exprs...)))
    end
end


#function A_mul_B_blas(a, b, c, A, B)
#q
#end

# The idea here is to get pointers to stack variables and call BLAS.
# This saves an aweful lot of time compared to copying SArray's to Ref{SArray{...}}
# and should be fastest for (very) large SArrays

# Here is an LLVM function that gets the pointer to its input, %x
# After this we would make the ccall above.
#
# define i8* @f(i32 %x) #0 {
#     %1 = alloca i32, align 4
#     store i32 %x, i32* %1, align 4
#     ret i32* %1
# }


@generated function A_mul_B!(C::StaticMatrix, A::StaticMatrix, B::StaticMatrix)
    if isbits(C)
        error("Cannot mutate $C")
    end

    TA = eltype(A)
    TB = eltype(B)
    T = promote_type(TA, TB)

    can_blas = T == TA && T == TB && T <: Union{Float64, Float32, Complex{Float64}, Complex{Float32}}

    if can_blas
        if size(A,1) * size(A,2) * size(A,3) < 4*4*4
            return quote
                $(Expr(:meta, :inline))
                A_mul_B_unrolled!(C, A, B)
                return C
            end
        elseif size(A,1) * size(A,2) * size(A,3) < 14*14*14 # Something seems broken for this one with large matrices (becomes allocating)
            return quote
                $(Expr(:meta, :inline))
                A_mul_B_unrolled_chunks!(C, A, B)
                return C
            end
        else
            return quote
                $(Expr(:meta, :inline))
                A_mul_B_blas!(C, A, B)
                return C
            end
        end
    else
        if size(A,1) * size(A,2) * size(A,3) < 4*4*4
            return quote
                $(Expr(:meta, :inline))
                A_mul_B_unrolled!(C, A, B)
                return C
            end
        else
            return quote
                $(Expr(:meta, :inline))
                A_mul_B_unrolled_chunks!(C, A, B)
                return C
            end
        end
    end
end

@generated function A_mul_B_blas!(C::StaticMatrix, A::StaticMatrix, B::StaticMatrix)
    sA = size(A)
    sB = size(B)
    TA = eltype(A)
    TB = eltype(B)

    s = size(C)
    T = eltype(C)

    if sB[1] != sA[2] || sA[1] != s[1] || sB[2] != s[2]
        error("Dimension mismatch")
    end

    if sA[1] > 0 && sA[2] > 0 && sB[2] > 0 && T == TA && T == TB && T <: Union{Float64, Float32, Complex{Float64}, Complex{Float32}}
        # This code adapted from `gemm!()` in base/linalg/blas.jl

        if T == Float64
            gemm = :dgemm_
        elseif T == Float32
            gemm = :sgemm_
        elseif T == Complex{Float64}
            gemm = :zgemm_
        else # T == Complex{Float32}
            gemm = :cgemm_
        end

        return quote
            alpha = $(one(T))
            beta = $(zero(T))
            transA = 'N'
            transB = 'N'
            m = $(sA[1])
            ka = $(sA[2])
            kb = $(sB[1])
            n = $(sB[2])
            strideA = $(sA[1])
            strideB = $(sB[1])
            strideC = $(s[1])

            ccall((Base.BLAS.@blasfunc($gemm), Base.BLAS.libblas), Void,
                (Ptr{UInt8}, Ptr{UInt8}, Ptr{Base.BLAS.BlasInt}, Ptr{Base.BLAS.BlasInt},
                 Ptr{Base.BLAS.BlasInt}, Ptr{$T}, Ptr{$T}, Ptr{Base.BLAS.BlasInt},
                 Ptr{$T}, Ptr{Base.BLAS.BlasInt}, Ptr{$T}, Ptr{$T},
                 Ptr{Base.BLAS.BlasInt}),
                 &transA, &transB, &m, &n,
                 &ka, &alpha, A, &strideA,
                 B, &strideB, &beta, C,
                 &strideC)
            return C
        end
    else
        error("Cannot call BLAS gemm with $C = $A * $B")
    end
end

@generated function A_mul_B_unrolled!(C::StaticMatrix, A::StaticMatrix, B::StaticMatrix)
    sA = size(A)
    sB = size(B)
    TA = eltype(A)
    TB = eltype(B)
    T = eltype(C)

    s = (sA[1], sB[2])

    if sB[1] != sA[2]
        error("Dimension mismatch")
    end

    if s != size(C)
        error("Dimension mismatch")
    end

    exprs = [:(C[$(sub2ind(s, k1, k2))] = $(reduce((ex1,ex2) -> :(+($ex1,$ex2)), [:(A[$(sub2ind(sA, k1, j))]*B[$(sub2ind(sB, j, k2))]) for j = 1:sA[2]]))) for k1 = 1:sA[1], k2 = 1:sB[2]]

    return quote
        $(Expr(:meta,:inline))
        @inbounds $(Expr(:block, exprs...))
    end
end

@generated function A_mul_B_unrolled_chunks!(C::StaticMatrix, A::StaticMatrix, B::StaticMatrix)
    sA = size(A)
    sB = size(B)
    TA = eltype(A)
    TB = eltype(B)

    s = size(C)
    T = eltype(C)

    if sB[1] != sA[2] || sA[1] != s[1] || sB[2] != s[2]
        error("Dimension mismatch")
    end

    #vect_exprs = [:($(Symbol("tmp_$k2")) = partly_unrolled_multiply(A, B[:, $k2])) for k2 = 1:sB[2]]

    # Do a custom B[:, k2] to return a SVector (an isbits type) rather than a mutable type. Avoids allocation == faster
    tmp_type = SVector{sB[1], T}
    vect_exprs = [:($(Symbol("tmp_$k2")) = partly_unrolled_multiply(A, $(Expr(:call, tmp_type, [Expr(:ref, :B, sub2ind(s, i, k2)) for i = 1:sB[1]]...)))) for k2 = 1:sB[2]]

    exprs = [:(C[$(sub2ind(s, k1, k2))] = $(Symbol("tmp_$k2"))[$k1]) for k1 = 1:sA[1], k2 = 1:sB[2]]

    return Expr(:block,
        Expr(:meta,:inline),
        vect_exprs...,
        exprs...
    )
end
