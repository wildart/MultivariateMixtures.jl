"Mixture of Factor Analyzers"
function fit_mm(::Type{FactorAnalysis}, X::AbstractMatrix{T};
                m::Integer = 2,        # the number of factor analyzers to use
                k::Integer = 1,        # the number of factors in each analyzer
                tol::Real=1.0e-6,      # convergence tolerance
                maxiter::Integer=1000, # number of iterations
                μs::Union{AbstractMatrix{T}, Nothing} = nothing,
                Σs::Union{AbstractArray{T,3}, Nothing} = nothing
            ) where T<:Real

    d, n = size(X)
    CMVN = (2π)^(-d/2)
    mX=mean(X, dims=2)
    cX=cov(X, dims=2)
    sc=det(cX)^(1/d)

    # initialize parameters
    πⱼ = fill(one(T)/m, m)
    Wⱼ = zeros(T,d,k,m)
    μⱼ = zeros(T,d,m)
    Ψⱼ = zeros(T,d,m)
    rn = 1:min(d,k)
    for j in 1:m
        if Σs !== nothing
            ev = eigvecs(Σs[:,:,j], sortby=-)
            Wⱼ[:,rn,j] = ev[:,rn].*sqrt(det(Σs[:,:,j])^(1/d))
        else
            Wⱼ[:,:,j] = randn(d,k) * sqrt(sc/k)
        end
        μⱼ[:,j] = μs !== nothing ? μs[:,j] : (vec(randn(d)' * sqrt(cX)) .+ mX)
        Ψⱼ[:,j] = diag(Σs !== nothing ? Σs[:,:,j] : cX) .+ eps()
    end

    hᵢⱼ = zeros(T,m,n)
    πᵢⱼ = similar(hᵢⱼ)
    E₍zzᵀₗxᵢωⱼ₎ = zeros(T,k,k,m)
    Σ⁻¹ⱼ = zeros(T,d,d,m)
    ZIᵀ=zeros(T,n,k+1,m)
    ZIᵀ[:,end,:] .= one(T)
    Σ⁻¹Y = similar(X)
    Y = similar(X)

    E₍zₗxᵢωⱼ₎ = view(ZIᵀ,:,1:k,:)

    L_old = 0.0
    for itr in 1:maxiter
        # E Step
        # 1) Calculate hᵢⱼ, E₍zₗxᵢωⱼ₎
        for j in 1:m
            Ψ⁻¹ = Diagonal(1 ./ Ψⱼ[:, j])
            W = @view Wⱼ[:,:,j]
            Σ⁻¹ = @view Σ⁻¹ⱼ[:,:,j]
            # V⁻¹ = inv(I + WᵀΨ⁻¹*W)
            WᵀΨ⁻¹ = W'*Ψ⁻¹
            # Σ⁻¹ = Ψ⁻¹ - Ψ⁻¹*W*V⁻¹*WᵀΨ⁻¹
            Σ⁻¹[:] = Ψ⁻¹ - Ψ⁻¹*W*inv(I + WᵀΨ⁻¹*W)*WᵀΨ⁻¹
            detΣ⁻¹ = sqrt(det(Σ⁻¹))
            # Y = X .- view(μⱼ,:,j)
            broadcast!(-,Y,X,view(μⱼ,:,j))
            Σ⁻¹Y .= Σ⁻¹*Y
            # view(hᵢⱼ,j,:) .= πⱼ[j]*(CMVN*detΣ⁻¹).*exp.(-0.5.*vec(sum(Y.*Σ⁻¹Y, dims=1)))
            broadcast!(*,Y,Y,Σ⁻¹Y)
            sum!(view(hᵢⱼ,j,:)', Y)
            c = πⱼ[j]*(CMVN*detΣ⁻¹)
            broadcast!(e->c*exp(-0.5*e),view(hᵢⱼ,j,:),view(hᵢⱼ,j,:))
            # Ez[:,:,j] = V⁻¹*WᵀΨ⁻¹*Y # W'*Σ⁻¹*Y
            view(E₍zₗxᵢωⱼ₎,:,:,j) .= (W'Σ⁻¹Y)'
        end

        # 2) Calculate log(L)
        hᵢⱼ[hᵢⱼ .< eps()] .= eps()
        hᵢ = sum(hᵢⱼ, dims=1)
        L = sum(log.(hᵢ))

        # 3) Calculate πⱼ
        # πᵢⱼ = hᵢⱼ./hᵢ
        broadcast!(/,πᵢⱼ,hᵢⱼ,hᵢ)
        πⱼ .= sum(πᵢⱼ, dims=2) |> vec

        # Check exit conditions
        if itr > 1
            chg = L - L_old
            if chg < 0
                @warn "log likelihood decreased" itr=itr change=chg
            end
            @debug "log(L)=$L" itr=itr increment=chg πⱼ=πⱼ' # Ψⱼ=Ψⱼ
            if (chg < tol)
                break
            end
        end
        L_old = L

        # 4) Calculate E₍zzᵀₗxᵢωⱼ₎
        for j in 1:m
            W = @view Wⱼ[:,:,j]
            Σ⁻¹ = @view Σ⁻¹ⱼ[:,:,j]
            broadcast!(-,Y,X,view(μⱼ,:,j))
            βⱼ = W'*Σ⁻¹
            Sᵢ = (view(πᵢⱼ, j, :)'.*Y)*Y'./πⱼ[j]
            view(E₍zzᵀₗxᵢωⱼ₎,:,:,j) .= I - βⱼ*W + βⱼ*Sᵢ*transpose(βⱼ)
        end

        # M Step
        for j in 1:m
            πᵢ = @view πᵢⱼ[j, :]
            broadcast!(*,Y,πᵢ',X) # πᵢ'.*X
            QWnum = Y*view(ZIᵀ,:,:,j)
            QWden1 = πⱼ[j]*view(E₍zzᵀₗxᵢωⱼ₎,:,:,j)
            QWden23 = view(E₍zₗxᵢωⱼ₎,:,:,j)'*πᵢ
            QWden = [QWden1 QWden23; QWden23' πⱼ[j]]
            R = QWnum/QWden

            Wⱼ[:,:,j] .= R[:,1:end-1]
            μⱼ[:,j] .= R[:,end]

            Ψⱼ[:,j] .= diag(Y*X' - R*QWnum')./πⱼ[j]
        end
    end
    return MixtureModel([FactorAnalysis(μⱼ[:,j], Wⱼ[:,:,j], Ψⱼ[:,j]) for j in 1:m], πⱼ./n)
end
