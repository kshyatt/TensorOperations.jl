function optimaltree(network, optdata::Dict)
    numtensors = length(network)
    allindices = unique(flatten(network))
    numindices = length(allindices)
    costtype = valtype(optdata)
    allcosts = [get(optdata, i, one(costtype)) for i in allindices]
    maxcost = prod(allcosts)*maximum(allcosts) + zero(costtype) # add zero for type stability: Power -> Poly
    tensorcosts = Vector{costtype}(numtensors)
    for k = 1:numtensors
        tensorcosts[k] = prod(get(optdata, i, one(costtype)) for i in network[k])
    end
    initialcost = min(maxcost, maximum(tensorcosts)^2 + zero(costtype)) # just some arbitrary guess

    if numindices <= 32
        return _optimaltree(UInt32, network, allindices, allcosts, initialcost, maxcost)
    elseif numindices <= 64
        return _optimaltree(UInt64, network, allindices, allcosts, initialcost, maxcost)
    elseif numindices <= 128
        return _optimaltree(UInt128, network, allindices, allcosts, initialcost, maxcost)
    else
        return _optimaltree(BitVector, network, allindices, allcosts, initialcost, maxcost)
    end
end

storeset(::Type{IntSet}, ints, maxint) = sizehint!(IntSet(ints), maxint)
function storeset(::Type{BitVector}, ints, maxint)
    set = falses(maxint)
    set[ints] = true
    return set
end
function storeset(::Type{T}, ints, maxint) where {T<:Unsigned}
    set = zero(T)
    u = one(T)
    for i in ints
        set |= (u<<(i-1))
    end
    return set
end
_intersect(s1::T, s2::T) where {T<:Unsigned} = s1 & s2
_intersect(s1::BitVector, s2::BitVector) = s1 .& s2
_intersect(s1::IntSet, s2::IntSet) = intersect(s1, s2)
_union(s1::T, s2::T) where {T<:Unsigned} = s1 | s2
_union(s1::BitVector, s2::BitVector) = s1 .| s2
_union(s1::IntSet, s2::IntSet) = union(s1, s2)
_setdiff(s1::T, s2::T) where {T<:Unsigned} = s1 & (~s2)
_setdiff(s1::BitVector, s2::BitVector) = s1 .& (.~s2)
_setdiff(s1::IntSet, s2::IntSet) = setdiff(s1, s2)
_isemptyset(s::Unsigned) = iszero(s)
_isemptyset(s::BitVector) = !any(s)
_isemptyset(s::IntSet) = isempty(s)

function computecost(allcosts, ind1::T, ind2::T) where {T<:Unsigned}
    cost = one(eltype(allcosts))
    ind = _union(ind1, ind2)
    n = 1
    while !iszero(ind)
        if isodd(ind)
            cost *= allcosts[n]
        end
        ind = ind>>1
        n += 1
    end
    return cost
end
function computecost(allcosts, ind1::BitVector, ind2::BitVector)
    cost = one(eltype(allcosts))
    ind = _union(ind1, ind2)
    for n in find(ind)
        cost *= allcosts[n]
    end
    return cost
end
function computecost(allcosts, ind1::IntSet, ind2::IntSet)
    cost = one(eltype(allcosts))
    ind = _union(ind1, ind2)
    for n in ind
        cost *= allcosts[n]
    end
    return cost
end

function _optimaltree(::Type{T}, network, allindices, allcosts::Vector{S}, initialcost::C, maxcost::C) where {T,S,C}
    numindices = length(allindices)
    numtensors = length(network)
    indexsets = Array{T}(numtensors)

    tabletensor = zeros(Int, (numindices,2))
    tableindex = zeros(Int, (numindices,2))

    adjacencymatrix=falses(numtensors,numtensors)
    costfac = maximum(allcosts)

    @inbounds for n = 1:numtensors
        indn = findin(allindices, network[n])
        indexsets[n] = storeset(T, indn, numindices)
        for i in indn
            if tabletensor[i,1] == 0
                tabletensor[i,1] = n
                tableindex[i,1] = findfirst(network[n], allindices[i])
            elseif tabletensor[i,2] == 0
                tabletensor[i,2] = n
                tableindex[i,2] = findfirst(network[n], allindices[i])
                n1 = tabletensor[i,1]
                adjacencymatrix[n1,n] = true
                adjacencymatrix[n,n1] = true
            else
                error("no index should appear more than two times")
            end
        end
    end
    componentlist = connectedcomponents(adjacencymatrix)
    numcomponent = length(componentlist)

    # generate output structures
    costlist = Vector{C}(numcomponent)
    treelist = Vector{Any}(numcomponent)
    indexlist = Vector{T}(numcomponent)

    # run over components
    for c=1:numcomponent
        # find optimal contraction for every component
        component = componentlist[c]
        componentsize = length(component)
        costdict = Array{Dict{T, C}}(componentsize)
        treedict = Array{Dict{T, Any}}(componentsize)
        indexdict = Array{Dict{T, T}}(componentsize)

        for k=1:componentsize
            costdict[k] = Dict{T, C}()
            treedict[k] = Dict{T, Any}()
            indexdict[k] = Dict{T, T}()
        end

        for i in component
            s = storeset(T, [i], numtensors)
            costdict[1][s] = zero(C)
            treedict[1][s] = i
            indexdict[1][s] = indexsets[i]
        end

        # run over currentcost
        currentcost = initialcost
        previouscost = zero(initialcost)
        while currentcost <= maxcost
            nextcost = maxcost
            # construct all subsets of n tensors that can be constructed with cost <= currentcost
            for n=2:componentsize
                # construct subsets by combining two smaller subsets
                for k = 1:div(n-1,2)
                    for s1 in keys(costdict[k]), s2 in keys(costdict[n-k])
                        if _isemptyset(_intersect(s1, s2)) && get(costdict[n], _union(s1, s2), currentcost) > previouscost
                            ind1 = indexdict[k][s1]
                            ind2 = indexdict[n-k][s2]
                            cind = _intersect(ind1, ind2)
                            if !_isemptyset(cind)
                                s = _union(s1, s2)
                                cost = costdict[k][s1] + costdict[n-k][s2] + computecost(allcosts, ind1, ind2)
                                if cost <= get(costdict[n], s, currentcost)
                                    costdict[n][s] = cost
                                    indexdict[n][s] = _setdiff(_union(ind1,ind2), cind)
                                    treedict[n][s] = (treedict[k][s1], treedict[n-k][s2])
                                elseif currentcost < cost < nextcost
                                    nextcost = cost
                                end
                            end
                        end
                    end
                end
                if iseven(n) # treat the case k = n/2 special
                    k = div(n,2)
                    it = keys(costdict[k])
                    state1 = start(it)
                    while !done(it, state1)
                        s1, nextstate1 = next(it, state1)
                        state2 = nextstate1
                        while !done(it, state2)
                            s2, nextstate2 = next(it, state2)
                            if _isemptyset(_intersect(s1, s2)) && get(costdict[n], _union(s1, s2), currentcost) > previouscost
                                ind1 = indexdict[k][s1]
                                ind2 = indexdict[k][s2]
                                cind = _intersect(ind1, ind2)
                                if !_isemptyset(cind)
                                    s = _union(s1, s2)
                                    cost = costdict[k][s1] + costdict[k][s2] + computecost(allcosts, ind1, ind2)
                                    if cost <= get(costdict[n], s, currentcost)
                                        costdict[n][s] = cost
                                        indexdict[n][s] = _setdiff(_union(ind1,ind2), cind)
                                        treedict[n][s] = (treedict[k][s1], treedict[k][s2])
                                    elseif currentcost < cost < nextcost
                                        nextcost = cost
                                    end
                                end
                            end
                            state2 = nextstate2
                        end
                        state1 = nextstate1
                    end
                end
            end
            if !isempty(costdict[componentsize])
                break
            end
            previouscost = currentcost
            currentcost = min(maxcost, nextcost*costfac)
        end
        if isempty(costdict[componentsize])
            error("Maxcost $maxcost reached without finding solution") # should be impossible
        end
        s = storeset(T, component, numtensors)
        costlist[c] = costdict[componentsize][s]
        treelist[c] = treedict[componentsize][s]
        indexlist[c] = indexdict[componentsize][s]
    end
    tree = treelist[1]
    cost = costlist[1]
    ind = indexlist[1]
    for c = 2:numcomponent
        tree = (tree, treelist[c])
        cost = cost + costlist[c] + computecost(allcosts, ind, indexlist[c])
        ind = _union(ind, indexlist[c])
    end
    return tree, cost
end

function connectedcomponents(A::AbstractMatrix{Bool})
    # For a given adjacency matrix of size n x n, connectedcomponents returns
    # a list componentlist that contains integer vectors, where every integer
    # vector groups the indices of the vertices of a connected component of the
    # graph encoded by A. The number of connected components is given by
    # length(componentlist).
    #
    # Used as auxiliary function to analyze contraction graph in contract.

    n=size(A,1)
    assert(size(A,2)==n)

    componentlist=Vector{Vector{Int}}()
    assignedlist=falses((n,))

    for i=1:n
        if !assignedlist[i]
            assignedlist[i]=true
            checklist=[i]
            currentcomponent=[i]
            while !isempty(checklist)
                j=pop!(checklist)
                for k=find(A[j,:])
                    if !assignedlist[k]
                        push!(currentcomponent,k)
                        push!(checklist,k)
                        assignedlist[k]=true;
                    end
                end
            end
            push!(componentlist,currentcomponent)
        end
    end
    return componentlist
end