using DataFrames
using Unitful

"""A struct to hold the depth-damage data"""
struct DepthDamageData

    # define the fields of the data structure
    depths::Vector{<:Unitful.Quantity{<:AbstractFloat,Unitful.𝐋}}
    damages::Vector{<:AbstractFloat}
    occupancy::AbstractString
    dmg_fn_id::AbstractString
    source::AbstractString
    description::AbstractString
    comment::AbstractString

    # we use an "inner constructor" to check that the lengths of the vectors are the same
    function DepthDamageData(depths, damages, args...; kwargs...)
        return if length(depths) == length(damages)
            new(depths, damages, args...; kwargs...)
        else
            error("depths and damages must be the same length")
        end
    end
end

"""Parse a row from a DataFrame, eg from `haz_fl_dept.csv`"""
function DepthDamageData(row::DataFrames.DataFrameRow)

    # get metadata fields
    occupancy = string(row.Occupancy)
    dmg_fn_id = string(row.DmgFnId)
    source = string(row.Source)
    description = string(row.Description)
    comment = string(row.Comment)

    # now get the depths and damages
    depths = Float64[]
    damages = Float64[]

    # Iterate over each column in the row
    for (col_name, value) in pairs(row)
        # Check if the column name starts with 'ft'
        if startswith(string(col_name), "ft")
            if value != "NA"
                # Convert column name to depth
                depth_str = string(col_name)[3:end] # Extract the part after 'ft'
                is_negative = endswith(depth_str, "m")
                depth_str = is_negative ? replace(depth_str, "m" => "") : depth_str
                depth_str = replace(depth_str, "_" => ".") # Replace underscore with decimal
                depth_val = parse(Float64, depth_str)
                depth_val = is_negative ? -depth_val : depth_val
                push!(depths, depth_val)

                # Add value to damages
                push!(damages, parse(Float64, string(value)))
            end
        end
    end

    # add appropriate units to them
    depths = depths .* 1.0u"ft"

    return DepthDamageData(
        depths, damages, occupancy, dmg_fn_id, source, description, comment
    )
end

"""
To make life simple, we can define a function that takes in some depths and some damages and *returns a function* that can be used to estimate damage at any depth.
"""
function get_depth_damage_function(
    depth_train::Vector{<:T}, dmg_train::Vector{<:AbstractFloat}
) where {T<:Unitful.Length}

    # interpolate
    depth_ft = ustrip.(u"ft", depth_train)
    interp_fn = Interpolations.LinearInterpolation(
        depth_ft, dmg_train; extrapolation_bc=Interpolations.Flat()
    )

    damage_fn = function (depth::T2) where {T2<:Unitful.Length}
        return interp_fn(ustrip.(u"ft", depth))
    end
    return damage_fn
end

"""
Get the function describing elevation cost as a function of house area
"""
function get_elevation_cost_function()

    # constants
    elevation_thresholds = [0 5.0 8.5 12.0 14.0][:] # piecewise linear
    elevation_rates = [80.36 82.5 86.25 103.75 113.75][:] # cost /ft / ft^2

    # interpolation
    elevation_itp = LinearInterpolation(elevation_thresholds, elevation_rates)

    # user-facing function
    function elevation_cost(Δh::T1, A::T2) where {T1<:Unitful.Length,T2<:Unitful.Area}
        area_ft2 = ustrip(u"ft^2", A)
        base_cost = (10000 + 300 + 470 + 4300 + 2175 + 3500) # in USD
        if Δh < 0.0u"ft"
            throw(DomainError(Δh, "Cannot lower the house"))
        elseif Δh ≈ 0.0u"ft"
            cost = 0.0
        elseif 0.0u"ft" < Δh <= 14.0u"ft"
            rate = elevation_itp(ustrip(u"ft", Δh))
            cost = base_cost + area_ft2 * rate
        else
            throw(DomainError(Δh, "Cannot elevate >14ft"))
        end
        return cost
    end

    return elevation_cost
end