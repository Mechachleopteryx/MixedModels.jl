
abstract type MixedModelFitCollection{T<:AbstractFloat} end # model with fixed and random effects


"""
    MixedModelBootstrap{T<:AbstractFloat} <: MixedModelFitCollection{T}

Object returned by `parametericbootstrap` with fields
- `fits`: the parameter estimates from the bootstrap replicates as a vector of named tuples.
- `λ`: `Vector{LowerTriangular{T,Matrix{T}}}` containing copies of the λ field from `ReMat` model terms
- `inds`: `Vector{Vector{Int}}` containing copies of the `inds` field from `ReMat` model terms
- `lowerbd`: `Vector{T}` containing the vector of lower bounds (corresponds to the identically named field of [`OptSummary`](@ref))
- `fcnames`: NamedTuple whose keys are the grouping factor names and whose values are the column names

The schema of `fits` is, by default,
```
Tables.Schema:
 :objective  T
 :σ          T
 :β          NamedTuple{β_names}{NTuple{p,T}}
 :se         StaticArrays.SArray{Tuple{p},T,1,p}
 :θ          StaticArrays.SArray{Tuple{k},T,1,k}
```
where the sizes, `p` and `k`, of the `β` and `θ` elements are determined by the model.

Characteristics of the bootstrap replicates can be extracted as properties.  The `σs` and
`σρs` properties unravel the `σ` and `θ` estimates into estimates of the standard deviations
and correlations of the random-effects terms.
"""
struct MixedModelBootstrap{T<:AbstractFloat} <: MixedModelFitCollection{T}
    fits::Vector
    λ::Vector{LowerTriangular{T,Matrix{T}}}
    inds::Vector{Vector{Int}}
    lowerbd::Vector{T}
    fcnames::NamedTuple
end

"""
    parametricbootstrap(rng::AbstractRNG, nsamp::Integer, m::MixedModel;
        β = coef(m), σ = m.σ, θ = m.θ, use_threads=false)
    parametricbootstrap(nsamp::Integer, m::MixedModel;
        β = coef(m), σ = m.σ, θ = m.θ, use_threads=false)

Perform `nsamp` parametric bootstrap replication fits of `m`, returning a `MixedModelBootstrap`.

The default random number generator is `Random.GLOBAL_RNG`.

# Named Arguments

`β`, `σ`, and `θ` are the values of `m`'s parameters for simulating the responses.
`σ` is only valid for `LinearMixedModel` and `GeneralizedLinearMixedModel` for
families with a dispersion parameter.
`use_threads` determines whether or not to use thread-based parallelism.

Note that `use_threads=true` may not offer a performance boost and may even
decrease peformance if multithreaded linear algebra (BLAS) routines are available.
In this case, threads at the level of the linear algebra may already occupy all
processors/processor cores. There are plans to provide better support in coordinating
Julia- and BLAS-level threads in the future.
"""
function parametricbootstrap(
    rng::AbstractRNG,
    n::Integer,
    morig::MixedModel{T};
    β::AbstractVector=coef(morig),
    σ=morig.σ,
    θ::AbstractVector=morig.θ,
    use_threads::Bool=false,
) where {T}
    if σ !== missing
        σ = T(σ)
    end
    β, θ = convert(Vector{T}, β), convert(Vector{T}, θ)
    βsc, θsc, p, k, m = similar(β), similar(θ), length(β), length(θ), deepcopy(morig)

    β_names = (Symbol.(fixefnames(morig))..., )
    rank = length(β_names)

    # we need arrays of these for in-place operations to work across threads
    m_threads = [m]
    βsc_threads = [βsc]
    θsc_threads = [θsc]

    if use_threads
        Threads.resize_nthreads!(m_threads)
        Threads.resize_nthreads!(βsc_threads)
        Threads.resize_nthreads!(θsc_threads)
    end
    # we use locks to guarantee thread-safety, but there might be better ways to do this for some RNGs
    # see https://docs.julialang.org/en/v1.3/manual/parallel-computing/#Side-effects-and-mutable-function-arguments-1
    # see https://docs.julialang.org/en/v1/stdlib/Future/index.html
    rnglock = ReentrantLock()
    samp = replicate(n, use_threads=use_threads) do
        mod = m_threads[Threads.threadid()]
        local βsc = βsc_threads[Threads.threadid()]
        local θsc = θsc_threads[Threads.threadid()]
        lock(rnglock)
        mod = simulate!(rng, mod, β = β, σ = σ, θ = θ)
        unlock(rnglock)
        refit!(mod)
        (
         objective = mod.objective,
         σ = mod.σ,
         β = NamedTuple{β_names}(fixef!(βsc, mod)),
         se = SVector{p,T}(stderror!(βsc, mod)),
         θ = SVector{k,T}(getθ!(θsc, mod)),
        )
    end
    MixedModelBootstrap(
        samp,
        deepcopy(morig.λ),
        getfield.(morig.reterms, :inds),
        copy(morig.optsum.lowerbd),
        NamedTuple{Symbol.(fnames(morig))}(map(t -> (t.cnames...,), morig.reterms)),
    )
end

function parametricbootstrap(
    nsamp::Integer,
    m::MixedModel;
    β = m.β,
    σ = m.σ,
    θ = m.θ,
    use_threads = false
)
    parametricbootstrap(Random.GLOBAL_RNG, nsamp, m, β=β, σ=σ, θ=θ, use_threads=use_threads)
end

"""
    allpars(bsamp::MixedModelFitCollection)

Return a tidy (column)table with the parameter estimates spread into columns
of `iter`, `type`, `group`, `name` and `value`.
"""
function allpars(bsamp::MixedModelFitCollection{T}) where {T}
    fits, λ, fcnames = bsamp.fits, bsamp.λ, bsamp.fcnames
    npars = 2 + length(first(fits).β) + sum(map(k -> (k * (k + 1)) >> 1, size.(bsamp.λ, 2)))
    nresrow = length(fits) * npars
    cols = (
        sizehint!(Int[], nresrow),
        sizehint!(String[], nresrow),
        sizehint!(Union{Missing,String}[], nresrow),
        sizehint!(Union{Missing,String}[], nresrow),
        sizehint!(T[], nresrow),
    )
    nrmdr = Vector{T}[]  # normalized rows of λ
    for (i, r) in enumerate(fits)
        σ = coalesce(r.σ, one(T))
        for (nm, v) in pairs(r.β)
            push!.(cols, (i, "β", missing, String(nm), v))
        end
        setθ!(bsamp, i)
        for (grp, ll) in zip(keys(fcnames), λ)
            rownms = getproperty(fcnames, grp)
            grpstr = String(grp)
            empty!(nrmdr)
            for (j, rnm, row) in zip(eachindex(rownms), rownms, eachrow(ll))
                push!.(cols, (i, "σ", grpstr, rnm, σ * norm(row)))
                push!(nrmdr, normalize(row))
                for k in 1:(j - 1)
                    push!.(cols, (
                        i,
                        "ρ",
                        grpstr,
                        string(rownms[k], ", ", rnm),
                        dot(nrmdr[j], nrmdr[k])
                    ))
                end
            end
        end
        r.σ === missing || push!.(cols, (i, "σ", "residual", missing, r.σ))
    end
    (
        iter=cols[1],
        type=PooledArray(cols[2]),
        group=PooledArray(cols[3]),
        names=PooledArray(cols[4]),
        value=cols[5],
    )
end

function Base.getproperty(bsamp::MixedModelFitCollection, s::Symbol)
    if s ∈ [:objective, :σ, :θ, :se]
        getproperty.(getfield(bsamp, :fits), s)
    elseif s == :β
        tidyβ(bsamp)
    elseif s == :coefpvalues
        coefpvalues(bsamp)
    elseif s == :σs
        tidyσs(bsamp)
    elseif s == :allpars
        allpars(bsamp)
    else
        getfield(bsamp, s)
    end
end

"""
    issingular(bsamp::MixedModelFitCollection)

Test each bootstrap sample for singularity of the corresponding fit.

Equality comparisons are used b/c small non-negative θ values are replaced by 0 in `fit!`.

See also [`issingular(::MixedModel)`](@ref).
"""
issingular(bsamp::MixedModelFitCollection) = map(θ -> any(θ .== bsamp.lowerbd), bsamp.θ)

function Base.propertynames(bsamp::MixedModelFitCollection)
    [:allpars, :objective, :σ, :β, :se, :coefpvalues, :θ, :σs, :λ, :inds, :lowerbd, :fits, :fcnames]
end

"""
    pvalues(::MixedModelFitCollection; estimator=mean, se=sem)

Compute p-values based on bootstrap samples.

P-values for βs and ρs are two-sided, p-values for σs are one-sided.

The approximation is based on Altman and Bland (2011), using the specified
`estimator` and `se` to compute a single estimate and standard error from
the fit collection.

Reference
----------
Altman, D.G. and J.M. Bland (2011). How to obtain the P value from a confidence interval.
BMJ; 343 :d2304 doi:10.1136/bmj.d2304
"""
function pvalues(bsamp::MixedModelFitCollection; estimator=mean, se=std)
    allpars = bsamp.allpars
    pars = unique(zip(allpars.type, allpars.group, allpars.names))

    colnms = (:type, :group, :names, :p)
    coltypes = Tuple{String, Union{Missing,String}, Union{Missing,String}, StatsBase.PValue}
    # not specifying the full eltype (NamedTuple{colnms,coltypes}) leads to prettier printing
    result = NamedTuple{colnms}[]
    sizehint!(result, length(pars))


    for (t, g, n) in pars
        gidx = if ismissing(g)
            ismissing.(allpars.group)
        else
            .!ismissing.(allpars.group) .& (allpars.group .== g)
        end

        nidx = if ismissing(n)
            ismissing.(allpars.names)
        else
            .!ismissing.(allpars.names) .& (allpars.names .== n)
        end

        tidx = allpars.type .== t # no missings allowed here

        idx = tidx .& gidx .& nidx

        vv = view(allpars.value, idx)
        z = estimator(vv) / se(vv)
        p = max(ccdf.(Chisq(1), abs2.(z)), 1 / length(vv))

        if t == "σ"
            p /= 2
        end

        push!(result, (; type=t, group=g, names=n, p=p))
    end

    return result
end

"""
    setθ!(bsamp::MixedModelFitCollection, i::Integer)

Install the values of the i'th θ value of `bsamp.fits` in `bsamp.λ`
"""
function setθ!(bsamp::MixedModelFitCollection, i::Integer)
    θ = bsamp.fits[i].θ
    offset = 0
    for (λ, inds) in zip(bsamp.λ, bsamp.inds)
        λdat = λ.data
        fill!(λdat, false)
        for j in eachindex(inds)
            λdat[inds[j]] = θ[j + offset]
        end
        offset += length(inds)
    end
    bsamp
end

"""
    shortestcovint(v, level = 0.95)

Return the shortest interval containing `level` proportion of the values of `v`
"""
function shortestcovint(v, level = 0.95)
    n = length(v)
    0 < level < 1 || throw(ArgumentError("level = $level should be in (0,1)"))
    vv = issorted(v) ? v : sort(v)
    ilen = Int(ceil(n * level)) # number of elements (counting endpoints) in interval
                                # skip non-finite elements at the ends of sorted vv
    start = findfirst(isfinite, vv)
    stop = findlast(isfinite, vv)
    if stop < (start + ilen - 1)
        return (vv[1], vv[end])
    end
    len, i = findmin([vv[i+ilen-1] - vv[i] for i = start:(stop+1-ilen)])
    (vv[i], vv[i + ilen - 1])
end

"""
    shortestcovint(bsamp::MixedModelBootstrap, level = 0.95)

Return the shortest interval containing `level` proportion for each parameter from `bsamp.allpars`
"""
function shortestcovint(bsamp::MixedModelBootstrap{T}, level = 0.95) where {T}
    allpars = bsamp.allpars
    pars = unique(zip(allpars.type, allpars.group, allpars.names))

    colnms = (:type, :group, :names, :lower, :upper)
    coltypes = Tuple{String, Union{Missing,String}, Union{Missing,String}, T, T}
    # not specifying the full eltype (NamedTuple{colnms,coltypes}) leads to prettier printing
    result = NamedTuple{colnms}[]
    sizehint!(result, length(pars))


    for (t, g, n) in pars
        gidx = if ismissing(g)
            ismissing.(allpars.group)
        else
            .!ismissing.(allpars.group) .& (allpars.group .== g)
        end

        nidx = if ismissing(n)
            ismissing.(allpars.names)
        else
            .!ismissing.(allpars.names) .& (allpars.names .== n)
        end

        tidx = allpars.type .== t # no missings allowed here

        idx = tidx .& gidx .& nidx

        vv = view(allpars.value, idx)

        lower, upper = shortestcovint(vv, level)
        push!(result, (; type=t, group=g, names=n, lower=lower, upper=upper))
    end

    return result
end

"""
    tidyβ(bsamp::MixedModelFitCollection)
Return a tidy (row)table with the parameter estimates spread into columns
of `iter`, `coefname` and `β`
"""
function tidyβ(bsamp::MixedModelFitCollection{T}) where {T}
    fits = bsamp.fits
    colnms = (:iter, :coefname, :β)
    result = sizehint!(
        NamedTuple{colnms,Tuple{Int,Symbol,T}}[],
        length(fits) * length(first(fits).β),
    )
    for (i, r) in enumerate(fits)
        for (k, v) in pairs(r.β)
            push!(result, NamedTuple{colnms}((i, k, v)))
        end
    end
    result
end

"""
    coefpvalues(bsamp::MixedModelFitCollection)

Return a rowtable with columns `(:iter, :coefname, :β, :se, :z, :p)`
"""
function coefpvalues(bsamp::MixedModelFitCollection{T}) where {T}
    fits = bsamp.fits
    colnms = (:iter, :coefname, :β, :se, :z, :p)
    result = sizehint!(
        NamedTuple{colnms,Tuple{Int,Symbol,T,T,T,T}}[],
        length(fits) * length(first(fits).β),
    )
    for (i, r) in enumerate(fits)
        for (p, s) in zip(pairs(r.β), r.se)
            β = last(p)
            z = β / s
            push!(result,
                NamedTuple{colnms}((i, first(p), β, s, z, 2normccdf(abs(z)))))
        end
    end
    result
end

"""
    tidyσs(bsamp::MixedModelFitCollection)
Return a tidy (row)table with the estimates of the variance components (on the standard deviation scale) spread into columns
of `iter`, `group`, `column` and `σ`.
"""
function tidyσs(bsamp::MixedModelFitCollection{T}) where {T}
    fits = bsamp.fits
    fcnames = bsamp.fcnames
    λ = bsamp.λ
    colnms = (:iter, :group, :column, :σ)
    result = sizehint!(
        NamedTuple{colnms,Tuple{Int,Symbol,Symbol,T}}[],
        length(fits) * sum(length, fcnames),
    )
    for (iter, r) in enumerate(fits)
        setθ!(bsamp, iter)    # install r.θ in λ
        σ = coalesce(r.σ, one(T))
        for (grp, ll) in zip(keys(fcnames), λ)
            for (cn, col) in zip(getproperty(fcnames, grp), eachrow(ll))
                push!(result, NamedTuple{colnms}((iter, grp, Symbol(cn), σ * norm(col))))
            end
        end
    end
    result
end
