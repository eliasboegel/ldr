module LDR
export Params, run_configurations
using DataFrames
using Statistics
using LinearAlgebra
using Parameters
using DelimitedFiles

# Definition of parameter struct containing default mission values
@with_kw struct Params
    R_e::Float64 = 6378.137e3  # [m]
    J2::Float64 = 0.00108263  # [-]
    mu::Float64 = 3.986004418e14  # [m3/s2]
    h_collision::Float64 = 789e3  # [m]
    d_n::Int64 = 100000  # number of fragments, change this number for simulation speed
    t0::Float64 = 5 * 24 * 3600  # 5 days
    h_offset::Float64 = 30e3  # [m]
    target_fraction::Float64 = 1 / 2
    max_dv::Float64 = 0.01 # Maximum dV used in gaussian perturbation equations
    FoV::Float64 = 38.44 * pi / 180  # [rad]
    range::Float64 = 250e3 # [m]
    incidence_angle::Float64 = 20 * pi / 180 # [rad]
    ablation_time::Float64 = 50 # [s]
    scan_time::Float64 = 5 # [s]
    cooldown_time::Float64 = 70
    fluence::Float64 = 8500 # [J/m^2]
    Cm::Float64 = 9.1078e-5 # [-]
    freq::Float64 = 55.79 # [Hz]
    min_perigee::Float64 = 340e3 # [m]
    t_max::Float64 = 2 * 365 * 24 * 3600 # [s], stop after 2 years
    bisect_tol::Float64 = 1 # [s]
end

# Kepler element order
# a = d_kepler[i, 1], semi-major axis
# e = d_kepler[i, 2], eccentricity
# inc = d_kepler[i, 3], inclination
# RAAN = d_kepler[i, 4], right ascension of ascending node
# w = d_kepler[i, 5], argument of pericenter
# M = d_kepler[i, 6], mean anomaly
# f = d_kepler[i, 7], true anomaly

# Iteratively compute true anomaly from mean anomaly and eccentricity
# Returns true anomaly
function compute_true_anomaly(e::Float64, M::Float64)
    # Initial guess
    E::Float64 = 0

    # Apply newton method 5x (reaches max precision after 5 iterations)
    for i::Int8 = 1:5
        E = E - (E - e * sin(E) - M) / (1 - e * cos(E))
    end

    # Final equation for true anomaly
    return 2 * atan(sqrt((1 + e) / (1 - e)) * tan(E / 2))
end

# Function to apply impulsive, directional dv to Kepler state
# Returns nothing, alters debris data passed in through parameters
function thrust_alter_orbit(params::Params, d_kepler::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, d_cartesian::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, d_cartesian_vel::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, d_dims, thrust_dir::Vector{Float64}, tot_dv::Float64)
    # Establish RTO (Radial, Transverse, Out-of-plane) axes (unit vectors)
    # Transforms thrust direction vector into RTO frame
    @inbounds R = normalize(d_cartesian)
    @inbounds O = normalize(cross(R, d_cartesian_vel))
    T = cross(O, R)
    thrust_dir_rto = Vector{Float64}(undef, 3)
    @inbounds thrust_dir_rto[1] = dot(thrust_dir, R)
    @inbounds thrust_dir_rto[2] = dot(thrust_dir, T)
    @inbounds thrust_dir_rto[3] = dot(thrust_dir, O)

    # Integration of Gaussian perturbation formulae with small dv to produce new Kepler orbit state after impulse application
    remaining_dv::Float64 = tot_dv
    while remaining_dv > 0
        # Determine dv for this timestep, takes max_dv for all steps except the last
        dv::Float64 = (remaining_dv / params.max_dv) < 1 ? mod(remaining_dv, params.max_dv) : params.max_dv
        dir_dv_rto::Vector{Float64} = thrust_dir_rto .* dv # Compute dv vector

        # Precompute certain common terms
        @inbounds sqramu::Float64 = sqrt(d_kepler[1] / params.mu)
        sqr1e2::Float64 = sqrt(1 - d_kepler[2] * d_kepler[2])
        @inbounds sinf::Float64 = sin(d_kepler[7])
        @inbounds cosf::Float64 = cos(d_kepler[7])
        @inbounds ecosf1::Float64 = d_kepler[2] * cosf + 1
        @inbounds n::Float64 = sqrt(params.mu / d_kepler[1]^3)

        # Apply Gaussian perturbation formulae
        @inbounds d_kepler[1] += sqramu * 2 * d_kepler[1] / sqr1e2 * (d_kepler[2] * sinf * dir_dv_rto[1] + ecosf1 * dir_dv_rto[2])
        @inbounds d_kepler[2] += sqramu * sqr1e2 * (sinf * dir_dv_rto[1] + (d_kepler[2] + 2 * cosf + d_kepler[2] * cosf * cosf) / ecosf1 * dir_dv_rto[2])
        @inbounds d_kepler[3] += sqramu * sqr1e2 / ecosf1 * cos(d_kepler[5] + d_kepler[7]) * dir_dv_rto[3]
        dRAAN::Float64 = sqramu * sqr1e2 / ecosf1 * sin(d_kepler[5] + d_kepler[7]) / sin(d_kepler[3]) * dir_dv_rto[3]
        @inbounds d_kepler[4] += dRAAN
        @inbounds d_kepler[5] += sqramu * sqr1e2 / d_kepler[2] * (-cosf * dir_dv_rto[1] + (ecosf1 + 1) / ecosf1 * sinf * dir_dv_rto[2]) - cos(d_kepler[3]) * dRAAN
        @inbounds d_kepler[6] += n + (1 - d_kepler[2] * d_kepler[2]) / (n * d_kepler[1] * d_kepler[2]) * ((cosf - 2 * d_kepler[2] / ecosf1) * dir_dv_rto[1] - (ecosf1 + 1) / ecosf1 * sinf * dir_dv_rto[2])

        remaining_dv -= params.max_dv
    end
end

# Function representing the range condition
# Returns True if debris object is in range, False otherwise
function in_range(params::Params, d_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, sc_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}) # Returns true if debris object is within range of spacecraft
    pos_rel::Vector{Float64} = sc_pos .- d_pos
    abs_distance::Float64 = norm(pos_rel)
    return abs_distance < params.range
end

# Function representing the incidence condition
# Returns True if angle between debris velocity and laser incidence direction is smaller than the max. incidence angle, False otherwise
function in_incidence(params::Params, d_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, d_vel::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, sc_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}) # Returns true if debris object meets the incidence angle requirement
    pos_rel::Vector{Float64} = sc_pos .- d_pos

    # Check angle between debris tranjectory and spacecraft relative to debris
    vel_rel_pos_angle::Float64 = acos(sum(d_vel .* pos_rel) / (norm(d_vel) * norm(pos_rel)))
    return vel_rel_pos_angle < params.incidence_angle
end

# Function representing the FoV condition
# Returns True if debris object is within detector FoV, False otherwise
function in_fov(params::Params, d_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, sc_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, sc_vel::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}) # Returns true if debris object meets the fov cone requirement
    pos_rel::Vector{Float64} = sc_pos .- d_pos

    laser_pointing_angle::Float64 = acos((params.R_e + params.h_collision) / (params.R_e + params.h_collision + params.h_offset))
    rotation_vector::Vector{Float64} = cross(sc_pos, -sc_vel) / norm(cross(sc_pos, -sc_vel))
    pointing_vector::Vector{Float64} = -sc_vel .* cos(laser_pointing_angle) + cross(rotation_vector, -sc_vel) .* sin(laser_pointing_angle) + rotation_vector .* (dot(rotation_vector, -sc_vel) * (1 - cos(laser_pointing_angle)))
    return acos(dot(pointing_vector, -pos_rel) / (norm(pointing_vector) * norm(-pos_rel))) < params.FoV / 2
end

# Function compositing the range, incidence angle and FoV condition functions
# Returns True if all conditions are met at the same time, False otherwise
function in_conditions(params::Params, d_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, d_vel::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, sc_pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, sc_vel::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true})
    return in_range(params, d_pos, sc_pos) &&
           in_incidence(params, d_pos, d_vel, sc_pos) &&
           in_fov(params, d_pos, sc_pos, sc_vel)
end

# Function to compute the time at which a debris object's in_condition state changed through a bisection algorithm
# Returns time at which in_condition state of object changed (up to tolerance level). If state did not change in interval, then return interval width
function bisect(params::Params, d_ref_kepler::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, sc_ref_kepler::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, t_ref::Float64, t_left::Float64, t_right::Float64, condition_func)
    # Compute sc and debris state at left interval bound
    sc_left_kepler::Matrix{Float64} = reshape(copy(sc_ref_kepler), 1, :)
    update(params, view(sc_left_kepler, 1, :), t_ref, t_left)
    sc_left_pos = Matrix{Float64}(undef, 1, 3)
    sc_left_vel = Matrix{Float64}(undef, 1, 3)
    compute_cartesian(params, view(sc_left_vel, 1, :), view(sc_left_pos, 1, :), view(sc_left_kepler, 1, :))
    d_left_kepler = reshape(copy(d_ref_kepler), 1, :)
    update(params, view(d_left_kepler, 1, :), t_ref, t_left)
    d_left_pos = Matrix{Float64}(undef, 1, 3)
    d_left_vel = Matrix{Float64}(undef, 1, 3)
    compute_cartesian(params, view(d_left_vel, 1, :), view(d_left_pos, 1, :), view(d_left_kepler, 1, :))
    condition_left = condition_func(params, view(d_left_pos, 1, :), view(d_left_vel, 1, :), view(sc_left_pos, 1, :), view(sc_left_vel, 1, :))

    # Compute sc and debris state at right interval bound
    sc_right_kepler = reshape(copy(sc_ref_kepler), 1, :)
    update(params, view(sc_right_kepler, 1, :), t_ref, t_right)
    sc_right_pos = Matrix{Float64}(undef, 1, 3)
    sc_right_vel = Matrix{Float64}(undef, 1, 3)
    compute_cartesian(params, view(sc_right_vel, 1, :), view(sc_right_pos, 1, :), view(sc_right_kepler, 1, :))
    d_right_kepler = reshape(copy(d_ref_kepler), 1, :)
    update(params, view(d_right_kepler, 1, :), t_ref, t_right)
    d_right_pos = Matrix{Float64}(undef, 1, 3)
    d_right_vel = Matrix{Float64}(undef, 1, 3)
    compute_cartesian(params, view(d_right_vel, 1, :), view(d_right_pos, 1, :), view(d_right_kepler, 1, :))
    condition_right = condition_func(params, view(d_right_pos, 1, :), view(d_right_vel, 1, :), view(sc_right_pos, 1, :), view(sc_right_vel, 1, :))

    # Allocate data for mid point
    sc_mid_kepler = reshape(copy(sc_ref_kepler), 1, :)
    d_mid_kepler = reshape(copy(d_ref_kepler), 1, :)
    sc_mid_pos = Matrix{Float64}(undef, 1, 3)
    sc_mid_vel = Matrix{Float64}(undef, 1, 3)
    d_mid_pos = Matrix{Float64}(undef, 1, 3)
    d_mid_vel = Matrix{Float64}(undef, 1, 3)

    # If left and right bound state is the same, then any visibility region between left and right is shorter than the minimum visibility time and can therefore be discarded
    if condition_left == condition_right
        return t_right * (t_ref == t_left) + t_left * (t_ref == t_right) # Depending on whether its the left or right bisection interval, return the respective maximum time span
    end

    t_mid::Float64 = 0
    while (t_right - t_left) > params.bisect_tol # Run until bisection interval is smaller than specified tolerance
        t_mid = (t_left + t_right) / 2 # Initial bisection mid point

        # Compute orbit state of spacecraft and debris object at t_mid
        update(params, view(sc_mid_kepler, 1, :), t_ref, t_mid)
        compute_cartesian(params, view(sc_mid_vel, 1, :), view(sc_mid_pos, 1, :), view(sc_mid_kepler, 1, :))
        update(params, view(d_mid_kepler, 1, :), t_ref, t_mid)
        compute_cartesian(params, view(d_mid_vel, 1, :), view(d_mid_pos, 1, :), view(d_mid_kepler, 1, :))

        # Evaluate condition function at t_mid
        condition_mid = condition_func(params, view(d_mid_pos, 1, :), view(d_mid_vel, 1, :), view(sc_mid_pos, 1, :), view(sc_mid_vel, 1, :))

        # Discard left iterval if change occurs in right interval and vice versa
        if condition_left == condition_mid
            t_left = t_mid
            condition_left = condition_mid
        else
            t_right = t_mid
        end
    end

    return t_mid # Last bisection interval mid point is the approximate time where object started meeting condition
end

# Function to compute Cartesian (x,y,z) position and velocity given a Kepler state
# Stores result in array slice passed as argument
function compute_cartesian(params::Params, vel::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, pos::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, kepler::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true})
    @inbounds p = kepler[1] * (1 - kepler[2] * kepler[2])
    @inbounds r = p / (1 + kepler[2] * cos(kepler[7]))
    h = sqrt(params.mu * p)

    @inbounds pos[1] = r * (cos(kepler[4]) * cos(kepler[5] + kepler[7]) - sin(kepler[4]) * sin(kepler[5] + kepler[7]) * cos(kepler[3]))
    @inbounds pos[2] = r * (sin(kepler[4]) * cos(kepler[5] + kepler[7]) + cos(kepler[4]) * sin(kepler[5] + kepler[7]) * cos(kepler[3]))
    @inbounds pos[3] = r * (sin(kepler[3]) * sin(kepler[5] + kepler[7]))
    @inbounds vel[1] = (pos[1] * h * kepler[2] / (r * p)) * sin(kepler[7]) - (h / r) * (cos(kepler[4]) * sin(kepler[5] + kepler[7]) + sin(kepler[4]) * cos(kepler[5] + kepler[7]) * cos(kepler[3]))
    @inbounds vel[2] = (pos[2] * h * kepler[2] / (r * p)) * sin(kepler[7]) - (h / r) * (sin(kepler[4]) * sin(kepler[5] + kepler[7]) - cos(kepler[4]) * cos(kepler[5] + kepler[7]) * cos(kepler[3]))
    @inbounds vel[3] = (pos[3] * h * kepler[2] / (r * p)) * sin(kepler[7]) + (h / r) * (cos(kepler[5] + kepler[7]) * sin(kepler[3]))
end

# Propagate object along its Kepler orbit, keeps a, e, i constant
# Modifies Kepler orbit data passed in as argument
function update(params::Params, kepler::SubArray{Float64,1,Matrix{Float64},Tuple{Int64,Base.Slice{Base.OneTo{Int64}}},true}, t_ref::Float64, t::Float64)
    dt = t - t_ref
    
    @inbounds n = sqrt(params.mu / kepler[1]^3) # Compute mean motion
    
    # Apply changes to RAAN and argument of pericenter due to J2
    @inbounds kepler[4] += -1.5 * n * params.R_e * params.R_e * params.J2 * cos(kepler[3]) / (kepler[1] * kepler[1]) / (1 - kepler[2] * kepler[2])^2 * dt # RAAN update
    @inbounds kepler[5] += 0.75 * n * params.R_e * params.R_e * params.J2 * (4 - 5 * (sin(kepler[3]))^2) / (kepler[1] * kepler[1]) / (1 - kepler[2] * kepler[2])^2 * dt # w update
    
    # Compute updated mean and true anomaly
    @inbounds kepler[6] += n * dt # Propagate mean anomaly
    @inbounds kepler[7] = compute_true_anomaly(kepler[2], kepler[6]) # Recompute true anomaly to fit new mean anomaly
end

# Function to read input data and execute a single model execution with given parameters and store results in CSV file
function run_sim(params::Params, run_idx)

    # Import data from NASA Standard Satellite Breakup Model CSV file
    mat, head = readdlm("iridium_cosmos_result.csv", ',', header=true)
    df = DataFrame(mat, vec(head))

    # Select fragments from Cosmos 2251 only and limit to correct size, remove debris objects already on course to deorbit naturally
    df = filter(row -> row.Name .== "Kosmos 2251-Collision-Fragment", df)
    df = filter(row -> row.d_eq .< 0.1, df)
    df = filter(row -> 0 .< row.e .< 1, df)
    df = filter(row -> (row.a * (1 - row.e) .> (params.R_e + params.min_perigee)) && (row.a * (1 + row.e) .> (params.R_e + params.min_perigee)), df) # Filter out all that already have a low enough perigee
    d_kepler = Matrix(select(df, ["a", "e", "i", "long_asc", "arg_peri", "mean_anom", "ID"])) # ID is used as an additional column to store true anomaly
    d_dims = Matrix(select(df, ["M", "A_M"]))

    # Cut data set down to set number of fragments, NOT used in ISSFD2024 data, pre-allocate variables
    tot_d_n::Int64 = min(params.d_n, length(d_kepler[:, 1]))
    println("Number of debris objects: ", tot_d_n)
    d_kepler::Matrix{Float64} = d_kepler[1:tot_d_n, :]
    d_semimajor_original::Vector{Float64} = d_kepler[:, 1]
    d_cartesian::Matrix{Float64} = Matrix{Float64}(undef, tot_d_n, 3)
    d_cartesian_vel::Matrix{Float64} = Matrix{Float64}(undef, tot_d_n, 3)
    d_removed::Matrix{Bool} = zeros(Bool, tot_d_n, 2)
    d_vis_times_pass::Vector{Float64} = zeros(tot_d_n)
    d_vis_prev::Vector{Float64} = zeros(Bool, tot_d_n)
    d_counter::Int64 = 0
    d_counter_prev::Int64 = 0
    increased_a_counter::Int64 = 0
    t::Float64 = params.t0
    t_last_pulse::Float64 = -Inf64
    ts = Vector{Float64}(undef, 0)
    percentages = Vector{Float64}(undef, 0)
    sc_pos::Matrix{Float64} = zeros(1, 3)
    sc_vel::Matrix{Float64} = zeros(1, 3)
    distances = zeros(tot_d_n)
    conditions = zeros(Bool, tot_d_n)
    filter_count::Int32 = 1
    filter_percent::Int32 = 1 # Cull removed objects every x percent removed

    # Preallocate ts and percentages vectors
    sizehint!(ts, 100000)
    sizehint!(percentages, 100000)

    # Propagate debris to t0
    Threads.@threads for i in axes(d_kepler, 1)
        update(params, view(d_kepler, i, :), 0.0, params.t0)
    end

    # Initialize spacecraft
    sc_kepler::Matrix{Float64} = transpose([
        params.R_e + params.h_collision + params.h_offset # a
        0 # e
        74 * pi / 180 # i, set to Cosmos-2251 inclination
        0 # RAAN, will be set to average debris RAAN at t0
        0 # w
        0 # M
        0 # f, will be overwritten
    ][:, :])
    update(params, view(sc_kepler, 1, :), 0.0, params.t0) # Propagate from t=0 to t=t0
    sc_kepler[1, 4] = mean(d_kepler[:, 4]) # Set RAAN to average spacecraft RAAN at t0
    sc_kepler[1, 6] = mean(d_kepler[:, 6]) # Set spacecraft mean anomaly to average mean anomaly at t0
    update(params, view(sc_kepler, 1, :), params.t0, params.t0) # Use update function to compute true anomaly after setting the mean anomaly

    # Main simulation loop, runs until target removal fraction is achieved or t_max is reached
    while (d_counter / tot_d_n < params.target_fraction) && t < params.t_max
        push!(ts, t - params.t0)

        # Propagate spacecraft and compute spacecraft position and velocity
        update(params, view(sc_kepler, 1, :), t, t + (params.scan_time + params.ablation_time))
        compute_cartesian(params, view(sc_vel, 1, :), view(sc_pos, 1, :), view(sc_kepler, 1, :))

        # Propagate debris and compute debris position and velocity, separate from below as this does not contain conditionals and can be parallelized better
        Threads.@threads for i in axes(d_kepler, 1)
            @inbounds update(params, view(d_kepler, i, :), t, t + (params.scan_time + params.ablation_time))
            @inbounds compute_cartesian(params, view(d_cartesian_vel, i, :), view(d_cartesian, i, :), view(d_kepler, i, :))
            @inbounds conditions[i] = in_conditions(params, view(d_cartesian, i, :), view(d_cartesian_vel, i, :), view(sc_pos, 1, :), view(sc_vel, 1, :))
        end

        # Perform more detailed evaluation of debris object to target
        for i in axes(d_kepler, 1)

            # Skip debris object if it is already marked as removed
            @inbounds if d_removed[i, 1]
                continue
            end

            # Only evaluate visibility time for fragment pass if coarser conditions have been met
            @inbounds if conditions[i]
                # Estimate visibility duration of fragmetn pass through bisection
                @inbounds t_begin = bisect(params, view(d_kepler, i, :), view(sc_kepler, 1, :), t, t - (params.scan_time + params.ablation_time), t, in_conditions)
                @inbounds t_end = bisect(params, view(d_kepler, i, :), view(sc_kepler, 1, :), t, t, t + (params.scan_time + params.ablation_time), in_conditions)
                @inbounds d_vis_times_pass[i] = t_end - t_begin

                # If fragment is visible long enough, apply dv according to debris object data
                if d_vis_times_pass[i] >= (params.scan_time + params.ablation_time)
                    @inbounds d_removed[i, 2] = true

                    @inbounds thrust_dir = -normalize(d_cartesian_vel[i, :]) # Direct thrust opposite of debris velocity
                    @inbounds deltav = params.fluence * params.Cm * params.freq * d_dims[i, 2] * params.ablation_time

                    @inbounds curr_true_anom = d_kepler[i, 7] * 180 / pi
                    @inbounds curr_alt = (d_kepler[i, 1] * (1 - d_kepler[i, 2] * d_kepler[i, 2]) / (1 + d_kepler[i, 2] * cos(d_kepler[i, 7])) - params.R_e)
                    @inbounds prev_perigee_alt = (d_kepler[i, 1] * (1 - d_kepler[i, 2]) - params.R_e)
                    @inbounds prev_apogee_alt = (d_kepler[i, 1] * (1 + d_kepler[i, 2]) - params.R_e)
                    @inbounds thrust_alter_orbit(params, view(d_kepler, i, :), view(d_cartesian, i, :), view(d_cartesian_vel, i, :), view(d_dims, i, :), thrust_dir, deltav) # Use views here
                    @inbounds new_perigee_alt = (d_kepler[i, 1] * (1 - d_kepler[i, 2]) - params.R_e)
                    @inbounds new_apogee_alt = (d_kepler[i, 1] * (1 + d_kepler[i, 2]) - params.R_e)

                    @inbounds d_removed[i, 1] = (new_perigee_alt < params.min_perigee) || (new_apogee_alt < params.min_perigee) || (d_kepler[i, 2] > 1) || (d_kepler[i, 2] < 0) # Mark object as removed if perigee is now below 200 km or if object was brought on hyperbolic trajectory
                    @inbounds d_counter += d_removed[i, 1]
                    @inbounds increased_a_counter += (d_semimajor_original[i] > (params.R_e + params.h_collision))

                    @inbounds d_vis_prev[i] = true
                    t_last_pulse = t

                    break # After laser was used, skip processing the other objects in this time step as system is now on cooldown
                end
            end
        end

        # If laser has shot, advance by cycle time + (params.scan_time + params.ablation_time), if not, only advance by (params.scan_time + params.ablation_time)
        if t == t_last_pulse
            t += (params.scan_time + params.ablation_time + params.cooldown_time) + (params.scan_time + params.ablation_time)
        else
            t += (params.scan_time + params.ablation_time)
        end
        push!(percentages, d_counter / tot_d_n) # Store removal percentage

        # Filter arrays every x% removed to improve runtime
        if mod(floor(d_counter / tot_d_n * 100), filter_percent) == 0 && floor(d_counter / tot_d_n * 100) == filter_count * filter_percent
            filter_count += 1
            @inbounds mask = .!d_removed[:, 2]
            @inbounds d_kepler = d_kepler[mask, :]
            @inbounds d_cartesian = d_cartesian[mask, :]
            @inbounds d_cartesian_vel = d_cartesian_vel[mask, :]
            @inbounds d_dims = d_dims[mask, :]
            @inbounds d_removed = d_removed[mask, :]
            @inbounds d_semimajor_original = d_semimajor_original[mask]
            @inbounds d_vis_times_pass = d_vis_times_pass[mask]
            @inbounds d_vis_prev = d_vis_prev[mask]
            @inbounds distances = distances[mask]
        end

        # Status message on simulation progress
        if d_counter_prev != d_counter
            println("Run ", run_idx, ": ", round(d_counter / tot_d_n * 100, digits=2), "% at ", round((t - params.t0) / (24 * 3600), digits=2), " days")
        end

        d_counter_prev = d_counter
    end
    increased_a_percentage::Float64 = increased_a_counter / d_counter * 100
    return (ts, percentages, increased_a_percentage)
end

# Function to take in a configuration file and run all configurations in it and store output in result CSV dataset.
# Skips configurations already present in result CSV dataset, 
function run_configurations(configurations, output_file)
    for idx = eachindex(configurations)
        # Skip configurations which already exist in the data file
        if isfile(output_file)
            mat, head = readdlm(output_file, ',', header=true)
            runs = DataFrame(mat, vec(head))
            res = filter(row -> isapprox(row."Collision altitude [m]", configurations[idx].h_collision) &&
                                    isapprox(row."#Fragments [-]", configurations[idx].d_n) &&
                                    isapprox(row."T_0 [days]", configurations[idx].t0 / (24 * 3600)) &&
                                    isapprox(row."SC Altitude Offset [m]", configurations[idx].h_offset) &&
                                    isapprox(row."Target Fraction [-]", configurations[idx].target_fraction) &&
                                    isapprox(row."FoV [deg]", configurations[idx].FoV * 180 / pi) &&
                                    isapprox(row."Range [m]", configurations[idx].range) &&
                                    isapprox(row."Incidence Angle [deg]", configurations[idx].incidence_angle * 180 / pi) &&
                                    isapprox(row."Ablation Time [s]", configurations[idx].ablation_time) &&
                                    isapprox(row."Scan Time [s]", configurations[idx].scan_time) &&
                                    isapprox(row."Cooldown Time [s]", configurations[idx].cooldown_time) &&
                                    isapprox(row."Fluence [J/m^2]", configurations[idx].fluence) &&
                                    isapprox(row."Removal Altitude [m]", configurations[idx].min_perigee), runs)

            if nrow(res) > 0
                println("Existing data using configuration ", idx, " detected. Skipping...")
                continue
            end
        end

        # Run simulation and record computation time
        @time (times, perc, perc_increased_a) = run_sim(configurations[idx], idx)
        time_required = last(times)
        fraction_removed = last(perc)
        println("Run ", idx, " finished! Time: ", round(time_required / (24 * 3600), digits=3), "days")

        # Store final time and removal fraction in result CSV dataset
        if filesize(output_file) == 0
            open(output_file, "w") do io
                writedlm(io, reshape(["Collision altitude [m]", "#Fragments [-]", "T_0 [days]", "SC Altitude Offset [m]", "Target Fraction [-]", "FoV [deg]", "Range [m]", "Incidence Angle [deg]", "Ablation Time [s]", "Scan Time [s]", "Cooldown Time [s]", "Fluence [J/m^2]", "Removal Altitude [m]", "Time Required [days]", "Fraction removed [-]"], 1, :), ",")
            end
        end
        open(output_file, "a") do io
            writedlm(io, reshape([configurations[idx].h_collision, float(configurations[idx].d_n), configurations[idx].t0 / (3600 * 24), configurations[idx].h_offset, configurations[idx].target_fraction, configurations[idx].FoV * 180 / pi, configurations[idx].range, configurations[idx].incidence_angle * 180 / pi, configurations[idx].ablation_time, configurations[idx].scan_time, configurations[idx].cooldown_time, configurations[idx].fluence, configurations[idx].min_perigee, time_required / (3600 * 24), fraction_removed], 1, :), ",")
        end
    end
end
end