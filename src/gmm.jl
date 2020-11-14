lower_bound(::Type{MV}, Rₙ, Rₙₖ) where {MV<:MultivariateNormal} = mean(e->iszero(e) ? -708 : log(e), Rₙₖ)
using Serialization

"Gaussian Mixture Model"
function fit_mm(::Type{MV}, X::AbstractMatrix{T}, k::Int;
                tol::Real=1e-5,             # convergence tolerance
                maxiter::Integer=100,       # number of iterations
                μs::Union{AbstractArray{T,2}, Nothing} = nothing,
                Σs::Union{AbstractArray{T,3}, Nothing} = nothing,
                homoscedastic::Bool=false,
                init::Symbol=:kmeans,
                logprob::Bool=true,
                covreg::Real=1e-6
            ) where {T<:AbstractFloat, MV<:MultivariateNormal}

    MINLOG = log(floatmin(T))
    d, n = size(X)
    Z = similar(X)
    Rₙ = zeros(T, n)
    Σ  = zeros(T, d, d)
    Off = similar(Rₙ)

    # initialize parameters
    πₖ, μₖ, Σₖ, Rₙₖ = initialize(MV, X, k, init=init)

    ℒ′ = Δℒ = typemin(T)
    for itr in 1:maxiter

        # E Step: Calculate posterior probability
        #   Rₙₖ = E[ωₖ|x] = p(ωₖ=1|x) ∝ πₖ⋅p(x|ωₖ) = πₖ⋅(√(2π)^(-d/2)*|Σₖ⁻¹|)⋅exp(-0.5⋅(x-μₖ)ᵀΣₖ⁻¹(x-μₖ))
        # where ωₖ is the mixture indicator variable, s.t. ωₖ = 1 when the data point was generated by mixture ωₖ
        for j in 1:k
            # remove the mean from the data
            broadcast!(-, Z, X, @view μₖ[:,j])
            # prepare covaranace inverse
            # Σ = @view Σₖ[:,:,j]
            Σ = Symmetric(Σₖ[:,:,j], :L)
            # calculate responsibilities
            if logprob
                Ch = cholesky!(Σ, check=false)
                !issuccess(Ch) && println("$itr, $j, $(Ch.info)")
                Ch.info<0 && error( "Cholesky factorization failed ($(Ch.info)). Try to decrease the number of components or increase `covreg`: $covreg.")
                # logpost!(view(Rₙₖ,:,j), πₖ[j], Ch, Z)
                # logpost!(view(Rₙₖ,:,j), πₖ[j], Symmetric(Σ), Z)
                logpost!(view(Rₙₖ,:,j), πₖ[j], Ch.L, Z)
            else
                posterior!(view(Rₙₖ,:,j), πₖ[j], Symmetric(Σ), Z)
            end
        end
        # Calculate (log) responsibilities
        if logprob
            logreps!(Rₙ, Rₙₖ, Off)
            # Rₙₖ[Rₙₖ .< 0] .= zero(T)
            # logreps!(Rₙ, Rₙₖ)
        else
            Rₙₖ[Rₙₖ .< eps(T)] .= eps(T)
            sum!(Rₙ, Rₙₖ)
            Rₙₖ ./= Rₙ
        end

        # M Step: Calculate parameters
        stats!(πₖ, μₖ, X, Rₙₖ)
        cov!(MV, Σₖ, πₖ, μₖ, X, Z, Rₙₖ, covreg=covreg)
        πₖ ./= n

        if homoscedastic
            Σₖ[:,:,1] .*= πₖ[1]
            for j in 2:k
                Σⱼ = view(Σₖ,:,:,j)
                Σⱼ .*= πₖ[j]
                Σₖ[:,:,1] .+= Σⱼ
            end
            for j in 2:k
                Σₖ[:,:,j] .= copy(Σₖ[:,:,1])
            end
        end

        # for j in 1:k
        #     # put restriction on the covariance matrix
        #     restrict_covariance!(MV, Σⱼ)
        # end

        # Check convergence
        ℒ = lower_bound(MV, Rₙ, Rₙₖ)
        Δℒ = abs(ℒ′ - ℒ)
        @debug "Likelihood" itr=itr ℒ=ℒ Δℒ=Δℒ
        (Δℒ < tol || isnan(Δℒ)) && break
        ℒ′ = ℒ
    end

    if Δℒ > tol
        @warn "No convergence" Δℒ=Δℒ tol=tol
    end

    return MixtureModel([distribution(MV, μₖ[:,j], Σₖ[:,:,j]) for j in 1:k], πₖ)
end

function init_covariance!(::Type{FullNormal}, Σₖ::AbstractMatrix, Σ::AbstractMatrix)
    # d = size(Σₖ,1)
    # sc=det(Σ)^(1/d)
    Σₖ .= Σ #.+rand(T,d,d) * sqrt(sc)
end

function init_covariance!(::Type{DiagNormal}, Σₖ::AbstractMatrix, Σ::AbstractMatrix)
    for i in 1:size(Σₖ,1)
        Σₖ[i,i] = Σ[i,i]
    end
end

function init_covariance!(::Type{IsoNormal}, Σₖ::AbstractMatrix, Σ::AbstractMatrix)
    d = size(Σₖ,1)
    σ = det(Σ)^(1/d)
    for i in 1:d
        Σₖ[i,i] = σ
    end
end

restrict_covariance!(::Type{FullNormal}, Σₖ::AbstractMatrix) = ()

function restrict_covariance!(::Type{DiagNormal}, Σₖ::AbstractMatrix)
    d = size(Σₖ,1)
    for i in 1:d, j in 1:d
        if i != j
            Σₖ[i,j] = 0
        end
    end
end

function restrict_covariance!(::Type{IsoNormal}, Σₖ::AbstractMatrix)
    d = size(Σₖ,1)
    σ = det(Σₖ)^(1/d)
    for i in 1:d, j in 1:d
        if i != j
            Σₖ[i,j] = 0
        else
            Σₖ[i,j] = σ
        end
    end
end

distribution(::Type{FullNormal}, μₖ::AbstractVector, Σₖ::AbstractMatrix) = MvNormal(μₖ, Symmetric(Σₖ))
distribution(::Type{DiagNormal}, μₖ::AbstractVector, Σₖ::AbstractMatrix) = MvNormal(μₖ, diag(Σₖ))
distribution(::Type{IsoNormal}, μₖ::AbstractVector, Σₖ::AbstractMatrix) = MvNormal(μₖ, Σₖ[1,1])
