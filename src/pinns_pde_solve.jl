using Base.Broadcast

"""
Override `Broadcast.__dot__` with `Broadcast.dottable(x::Function) = true`

# Example

```julia
julia> e = :(1 + $sin(x))
:(1 + (sin)(x))

julia> Broadcast.__dot__(e)
:((+).(1, (sin)(x)))

julia> _dot_(e)
:((+).(1, (sin).(x)))
```
"""
dottable_(x) = Broadcast.dottable(x)
dottable_(x::Function) = true

_dot_(x) = x
function _dot_(x::Expr)
    dotargs = Base.mapany(_dot_, x.args)
    if x.head === :call && dottable_(x.args[1])
        Expr(:., dotargs[1], Expr(:tuple, dotargs[2:end]...))
    elseif x.head === :comparison
        Expr(:comparison, (iseven(i) && dottable_(arg) && arg isa Symbol && isoperator(arg) ?
                               Symbol('.', arg) : arg for (i, arg) in pairs(dotargs))...)
    elseif x.head === :$
        x.args[1]
    elseif x.head === :let # don't add dots to `let x=...` assignments
        Expr(:let, undot(dotargs[1]), dotargs[2])
    elseif x.head === :for # don't add dots to for x=... assignments
        Expr(:for, undot(dotargs[1]), dotargs[2])
    elseif (x.head === :(=) || x.head === :function || x.head === :macro) &&
           Meta.isexpr(x.args[1], :call) # function or macro definition
        Expr(x.head, x.args[1], dotargs[2])
    elseif x.head === :(<:) || x.head === :(>:)
        tmp = x.head === :(<:) ? :.<: : :.>:
        Expr(:call, tmp, dotargs...)
    else
        head = String(x.head)::String
        if last(head) == '=' && first(head) != '.' || head == "&&" || head == "||"
            Expr(Symbol('.', head), dotargs...)
        else
            Expr(x.head, dotargs...)
        end
    end
end

RuntimeGeneratedFunctions.init(@__MODULE__)

"""
Algorithm for solving Physics-Informed Neural Networks problems.

Arguments:
* `chain`: a Flux.jl chain with a d-dimensional input and a 1-dimensional output,
* `strategy`: determines which training strategy will be used,
* `init_params`: the initial parameter of the neural network,
* `phi`: a trial solution,
* `derivative`: method that calculates the derivative.

"""
abstract type AbstractPINN{isinplace} <: SciMLBase.SciMLProblem end

struct PhysicsInformedNN{isinplace,C,T,P,PH,DER,PE,AL,K} <: AbstractPINN{isinplace}
  chain::C
  strategy::T
  init_params::P
  phi::PH
  derivative::DER
  param_estim::PE
  additional_loss::AL
  kwargs::K

  @add_kwonly function PhysicsInformedNN{iip}(chain,
                                             strategy;
                                             init_params = nothing,
                                             phi = nothing,
                                             derivative = nothing,
                                             param_estim=false,
                                             additional_loss=nothing,
                                             kwargs...) where iip
        if init_params == nothing
            if chain isa AbstractArray
                init?? = DiffEqFlux.initial_params.(chain)
            else
                init?? = DiffEqFlux.initial_params(chain)
            end

        else
            init?? = init_params
        end
        type_init?? = if (typeof(chain) <: AbstractVector) Base.promote_typeof.(init??)[1] else  Base.promote_typeof(init??) end
        parameterless_type_?? = DiffEqBase.parameterless_type(type_init??)

        if phi == nothing
            if chain isa AbstractArray
                _phi = get_phi.(chain,parameterless_type_??)
            else
                _phi = get_phi(chain,parameterless_type_??)
            end
        else
            _phi = phi
        end

        if derivative == nothing
            _derivative = get_numeric_derivative()
        else
            _derivative = derivative
        end
        new{iip,typeof(chain),typeof(strategy),typeof(init??),typeof(_phi),typeof(_derivative),typeof(param_estim),typeof(additional_loss),typeof(kwargs)}(chain,strategy,init??,_phi,_derivative,param_estim,additional_loss,kwargs)
    end
end
PhysicsInformedNN(chain,strategy,args...;kwargs...) = PhysicsInformedNN{true}(chain,strategy,args...;kwargs...)

SciMLBase.isinplace(prob::PhysicsInformedNN{iip}) where iip = iip


abstract type TrainingStrategies  end

"""
* `dx`: the discretization of the grid.
"""
struct GridTraining <: TrainingStrategies
    dx
end

"""
* `points`: number of points in random select training set,
* `bcs_points`: number of points in random select training set for boundry conditions (by default, it equals `points`).
"""
struct StochasticTraining <:TrainingStrategies
    points:: Int64
    bcs_points:: Int64
end
function StochasticTraining(points;bcs_points = points)
    StochasticTraining(points, bcs_points)
end
"""
* `points`:  the number of quasi-random points in a sample,
* `bcs_points`: the number of quasi-random points in a sample for boundry conditions (by default, it equals `points`),
* `sampling_alg`: the quasi-Monte Carlo sampling algorithm,
* `resampling`: if it's false - the full training set is generated in advance before training,
   and at each iteration, one subset is randomly selected out of the batch.
   if it's true - the training set isn't generated beforehand, and one set of quasi-random
   points is generated directly at each iteration in runtime. In this case `minibatch` has no effect,
* `minibatch`: the number of subsets, if resampling == false.

For more information look: QuasiMonteCarlo.jl https://github.com/SciML/QuasiMonteCarlo.jl
"""
struct QuasiRandomTraining <:TrainingStrategies
    points:: Int64
    bcs_points:: Int64
    sampling_alg::QuasiMonteCarlo.SamplingAlgorithm
    resampling:: Bool
    minibatch:: Int64
end
function QuasiRandomTraining(points;bcs_points = points, sampling_alg = LatinHypercubeSample(),resampling =true, minibatch=0)
    QuasiRandomTraining(points,bcs_points,sampling_alg,resampling,minibatch)
end
"""
* `quadrature_alg`: quadrature algorithm,
* `reltol`: relative tolerance,
* `abstol`: absolute tolerance,
* `maxiters`: the maximum number of iterations in quadrature algorithm,
* `batch`: the preferred number of points to batch.

For more information look: Quadrature.jl https://github.com/SciML/Quadrature.jl
"""
struct QuadratureTraining <: TrainingStrategies
    quadrature_alg::DiffEqBase.AbstractQuadratureAlgorithm
    reltol::Float64
    abstol::Float64
    maxiters::Int64
    batch::Int64
end

function QuadratureTraining(;quadrature_alg=CubatureJLh(),reltol= 1e-6,abstol= 1e-3,maxiters=1e3,batch=100)
    QuadratureTraining(quadrature_alg,reltol,abstol,maxiters,batch)
end

"""
Create dictionary: variable => unique number for variable

# Example 1

Dict{Symbol,Int64} with 3 entries:
  :y => 2
  :t => 3
  :x => 1

# Example 2

 Dict{Symbol,Int64} with 2 entries:
  :u1 => 1
  :u2 => 2
"""
get_dict_vars(vars) = Dict( [Symbol(v) .=> i for (i,v) in enumerate(vars)])

# Wrapper for _transform_expression
function transform_expression(ex,indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative,integral,init??;is_integral=false)
    if ex isa Expr
        ex = _transform_expression(ex,indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative,integral,init??;is_integral = is_integral)
    end
    return ex
end

function get_??(dim, der_num,eltype??)
    epsilon = cbrt(eps(eltype??))
    ?? = zeros(eltype??, dim)
    ??[der_num] = epsilon
    ??
end

function get_limits(domain)
    if domain isa AbstractInterval
        return [leftendpoint(domain)], [rightendpoint(domain)]
    elseif domain isa ProductDomain
        return collect(map(leftendpoint , DomainSets.components(domain))), collect(map(rightendpoint , DomainSets.components(domain)))
    end
end


?? = gensym("??")

"""
Transform the derivative expression to inner representation

# Examples

1. First compute the derivative of function 'u(x,y)' with respect to x.

Take expressions in the form: `derivative(u(x,y), x)` to `derivative(phi, u, [x, y], ??s, order, ??)`,
where
 phi - trial solution
 u - function
 x,y - coordinates of point
 ??s - epsilon mask
 order - order of derivative
 ?? - weight in neural network
"""
function _transform_expression(ex,indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative_,integral,init??;is_integral=false)
    _args = ex.args
    for (i,e) in enumerate(_args)
        if !(e isa Expr)
            if e in keys(dict_depvars)
                depvar = _args[1]
                num_depvar = dict_depvars[depvar]
                indvars = _args[2:end]
                var_ = is_integral ? :(u) : :($(Expr(:$, :u)))
                ex.args = if !(typeof(chain) <: AbstractVector)
                    [var_, Symbol(:cord, num_depvar), :($??), :phi]
                else
                    [var_, Symbol(:cord, num_depvar), Symbol(:($??), num_depvar), Symbol(:phi, num_depvar)]
                end
                break
            elseif e isa ModelingToolkit.Differential
                derivative_variables = Symbol[]
                order = 0
                while (_args[1] isa ModelingToolkit.Differential)
                    order += 1
                    push!(derivative_variables, toexpr(_args[1].x))
                    _args = _args[2].args
                end
                depvar = _args[1]
                num_depvar = dict_depvars[depvar]
                indvars = _args[2:end]
                dict_interior_indvars = Dict([indvar .=> j for (j, indvar) in enumerate(dict_depvar_input[depvar])])                
                dim_l = length(dict_interior_indvars)

                var_ = is_integral ? :(derivative) : :($(Expr(:$, :derivative)))
                ??s = [get_??(dim_l, d, eltype??) for d in 1:dim_l]
                undv = [dict_interior_indvars[d_p] for d_p  in derivative_variables]
                ??s_dnv = [??s[d] for d in undv]

                ex.args = if !(typeof(chain) <: AbstractVector)
                    [var_, :phi, :u, Symbol(:cord, num_depvar), ??s_dnv, order, :($??)]
                else
                    [var_, Symbol(:phi, num_depvar), :u, Symbol(:cord, num_depvar), ??s_dnv, order, Symbol(:($??), num_depvar)]
                end
                break
            elseif e isa Symbolics.Integral
                if _args[1].domain.variables isa Tuple
                    integrating_variable_ = collect(_args[1].domain.variables)
                    integrating_variable = toexpr.(integrating_variable_)
                    integrating_var_id = [dict_indvars[i] for i in integrating_variable]
                else
                    integrating_variable = toexpr(_args[1].domain.variables)
                    integrating_var_id = [dict_indvars[integrating_variable]]
                end

                integrating_depvars = []
                integrand_expr =_args[2]
                for d in depvars
                    d_ex = find_thing_in_expr(integrand_expr,d)
                    if !isempty(d_ex)
                        push!(integrating_depvars, d_ex[1].args[1])
                    end
                end
 
                num_depvar = map(int_depvar -> dict_depvars[int_depvar], integrating_depvars)
                integrand_ = transform_expression(_args[2],indvars,depvars,dict_indvars,dict_depvars,
                                                dict_depvar_input, chain,eltype??,strategy,
                                                phi,derivative_,integral,init??; is_integral = false)
                integrand__ = _dot_(integrand_)
                integrand = build_symbolic_loss_function(nothing, indvars,depvars,dict_indvars,dict_depvars,
                                                         dict_depvar_input, phi, derivative_, nothing, chain,
                                                         init??, strategy, integrand = integrand__,
                                                         integrating_depvars=integrating_depvars,
                                                         eq_params=SciMLBase.NullParameters(),
                                                         param_estim =false, default_p = nothing)
                # integrand = repr(integrand)
                lb, ub = get_limits(_args[1].domain.domain)
                lb = toexpr.(lb)
                ub = toexpr.(ub)
                ub_ = []
                lb_ = []
                for l in lb
                    if l isa Number
                        push!(lb_, l)
                    else

                        l_expr = NeuralPDE.build_symbolic_loss_function(nothing, indvars,depvars,
                                                                   dict_indvars,dict_depvars,
                                                                   dict_depvar_input, phi, derivative_,
                                                                   nothing, chain, init??, strategy,
                                                                   integrand = l, integrating_depvars=integrating_depvars,
                                                                   param_estim =false, default_p = nothing)
                        l_f = @RuntimeGeneratedFunction(l_expr)
                        push!(lb_, l_f)
                    end
                end
                for u_ in ub
                    if u_ isa Number
                        push!(ub_, u_)
                    else
                        u_expr = NeuralPDE.build_symbolic_loss_function(nothing, indvars,depvars,
                                                                    dict_indvars,dict_depvars,
                                                                    dict_depvar_input, phi, derivative_,
                                                                    nothing, chain, init??, strategy,
                                                                    integrand = u_, integrating_depvars=integrating_depvars,
                                                                    param_estim =false, default_p = nothing)
                        u_f = @RuntimeGeneratedFunction(u_expr)
                        push!(ub_, u_f)
                    end
                end

                integrand_func = @RuntimeGeneratedFunction(integrand)
                ex.args = [:($(Expr(:$, :integral))), :u, Symbol(:cord, num_depvar[1]), :phi, integrating_var_id, integrand_func, lb_, ub_,  :($??)]
                break
            end
        else
            ex.args[i] = _transform_expression(ex.args[i],indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative_,integral,init??; is_integral = is_integral)
        end
    end
    return ex
end

"""
Parse ModelingToolkit equation form to the inner representation.

Example:

1)  1-D ODE: Dt(u(t)) ~ t +1

    Take expressions in the form: 'Equation(derivative(u(t), t), t + 1)' to 'derivative(phi, u_d, [t], [[??]], 1, ??) - (t + 1)'

2)  2-D PDE: Dxx(u(x,y)) + Dyy(u(x,y)) ~ -sin(pi*x)*sin(pi*y)

    Take expressions in the form:
     Equation(derivative(derivative(u(x, y), x), x) + derivative(derivative(u(x, y), y), y), -(sin(??x)) * sin(??y))
    to
     (derivative(phi,u, [x, y], [[??,0],[??,0]], 2, ??) + derivative(phi, u, [x, y], [[0,??],[0,??]], 2, ??)) - -(sin(??x)) * sin(??y)

3)  System of PDEs: [Dx(u1(x,y)) + 4*Dy(u2(x,y)) ~ 0,
                    Dx(u2(x,y)) + 9*Dy(u1(x,y)) ~ 0]

    Take expressions in the form:
    2-element Array{Equation,1}:
        Equation(derivative(u1(x, y), x) + 4 * derivative(u2(x, y), y), ModelingToolkit.Constant(0))
        Equation(derivative(u2(x, y), x) + 9 * derivative(u1(x, y), y), ModelingToolkit.Constant(0))
    to
      [(derivative(phi1, u1, [x, y], [[??,0]], 1, ??1) + 4 * derivative(phi2, u, [x, y], [[0,??]], 1, ??2)) - 0,
       (derivative(phi2, u2, [x, y], [[??,0]], 1, ??2) + 9 * derivative(phi1, u, [x, y], [[0,??]], 1, ??1)) - 0]
"""

function build_symbolic_equation(eq,_indvars,_depvars,chain,eltype??,strategy,phi,derivative,init??)
    depvars,indvars,dict_indvars,dict_depvars, dict_depvar_input = get_vars(_indvars, _depvars)
    parse_equation(eq,indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative,integral,init??)
end

function parse_equation(eq,indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative,integral,init??)
    eq_lhs = isequal(expand_derivatives(eq.lhs), 0) ? eq.lhs : expand_derivatives(eq.lhs)
    eq_rhs = isequal(expand_derivatives(eq.rhs), 0) ? eq.rhs : expand_derivatives(eq.rhs)
    left_expr = transform_expression(toexpr(eq_lhs),indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative,integral,init??)
     right_expr = transform_expression(toexpr(eq_rhs),indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative,integral,init??)
    left_expr = _dot_(left_expr)
    right_expr = _dot_(right_expr)
    loss_func = :($left_expr .- $right_expr)
end

"""
Build a loss function for a PDE or a boundary condition

# Examples: System of PDEs:

Take expressions in the form:

[Dx(u1(x,y)) + 4*Dy(u2(x,y)) ~ 0,
 Dx(u2(x,y)) + 9*Dy(u1(x,y)) ~ 0]

to

:((cord, ??, phi, derivative, u)->begin
          #= ... =#
          #= ... =#
          begin
              (??1, ??2) = (??[1:33], ??"[34:66])
              (phi1, phi2) = (phi[1], phi[2])
              let (x, y) = (cord[1], cord[2])
                  [(+)(derivative(phi1, u, [x, y], [[??, 0.0]], 1, ??1), (*)(4, derivative(phi2, u, [x, y], [[0.0, ??]], 1, ??2))) - 0,
                   (+)(derivative(phi2, u, [x, y], [[??, 0.0]], 1, ??2), (*)(9, derivative(phi1, u, [x, y], [[0.0, ??]], 1, ??1))) - 0]
              end
          end
      end)
"""
function build_symbolic_loss_function(eqs,_indvars,_depvars,dict_depvar_input,
                                      phi, derivative,integral,chain,init??,strategy;
                                      bc_indvars=nothing,
                                      eq_params = SciMLBase.NullParameters(),
                                      param_estim = false,
                                      default_p=nothing,
                                      integrand=nothing,
                                      integration_indvars=nothing,
                                      integrating_depvars=nothing)
    # dictionaries: variable -> unique number
    depvars, indvars, dict_indvars, dict_depvars, dict_depvar_input = get_vars(_indvars, _depvars)
    bc_indvars = bc_indvars == nothing ? indvars : bc_indvars
    integration_indvars = integration_indvars == nothing ? indvars : integration_indvars
    integrating_depvars = integrating_depvars == nothing ? depvars : integrating_depvars
    return build_symbolic_loss_function(eqs,indvars,depvars,
                                        dict_indvars,dict_depvars,dict_depvar_input,
                                        phi,derivative,integral,chain,init??,strategy;
                                        bc_indvars = bc_indvars,
                                        eq_params = eq_params,
                                        param_estim = param_estim,
                                        default_p=default_p,
                                        integrand=integrand,
                                        integration_indvars=integration_indvars,
                                        integrating_depvars=integrating_depvars)
end

function get_indvars_ex(bc_indvars) # , dict_this_eq_indvars)
    i_=1
    indvars_ex = map(bc_indvars) do u
        if u isa Symbol
             # i = dict_this_eq_indvars[u]
             # ex = :($:cord[[$i],:])
             ex = :($:cord[[$i_],:])
             i_+=1
             ex
        else
           :(fill($u,size($:cord[[1],:])))
        end
    end
    indvars_ex
end

"""
Finds which dependent variables are being used in an equation.
"""
function pair(eq, depvars, dict_depvars, dict_depvar_input)
    expr = toexpr(eq)
    pair_ = map(depvars) do depvar
        if !isempty(find_thing_in_expr(expr,  depvar))
            dict_depvars[depvar] => dict_depvar_input[depvar]
        end
    end
    Dict(filter(p -> p !== nothing, pair_))
end

function build_symbolic_loss_function(eqs,indvars,depvars,
                                      dict_indvars,dict_depvars,dict_depvar_input,
                                      phi,derivative,integral,chain,init??,strategy;
                                      eq_params = SciMLBase.NullParameters(),
                                      param_estim = param_estim,
                                      default_p=default_p,
                                      bc_indvars=indvars,
                                      integrand=nothing,
                                      integration_indvars=indvars,
                                      integrating_depvars=depvars,
                                      )
    if chain isa AbstractArray
        eltype?? = eltype(init??[1])
    else
        eltype?? = eltype(init??)
    end

    if integrand isa Nothing
        loss_function = parse_equation(eqs,indvars,depvars,dict_indvars,dict_depvars,dict_depvar_input,chain,eltype??,strategy,phi,derivative,integral,init??)
        this_eq_pair = pair(eqs, depvars, dict_depvars, dict_depvar_input)
        this_eq_indvars = unique(vcat(values(this_eq_pair)...))
    else 
        this_eq_pair = Dict(map(intvars -> dict_depvars[intvars] => dict_depvar_input[intvars], integrating_depvars))
        this_eq_indvars = unique(vcat(values(this_eq_pair)...))
        loss_function = integrand
    end
    vars = :(cord, $??, phi, derivative, integral,u,p)
    ex = Expr(:block)
    if typeof(chain) <: AbstractVector
        ??_nums = Symbol[]
        phi_nums = Symbol[]
        for v in depvars
            num = dict_depvars[v]
            push!(??_nums,:($(Symbol(:($??),num))))
            push!(phi_nums,:($(Symbol(:phi,num))))
        end

        expr_?? = Expr[]
        expr_phi = Expr[]

        acum =  [0;accumulate(+, length.(init??))]
        sep = [acum[i]+1 : acum[i+1] for i in 1:length(acum)-1]

        for i in eachindex(depvars)
            push!(expr_??, :($??[$(sep[i])]))
            push!(expr_phi, :(phi[$i]))
        end

        vars_?? = Expr(:(=), build_expr(:tuple, ??_nums), build_expr(:tuple, expr_??))
        push!(ex.args,  vars_??)

        vars_phi = Expr(:(=), build_expr(:tuple, phi_nums), build_expr(:tuple, expr_phi))
        push!(ex.args,  vars_phi)
    end
    #Add an expression for parameter symbols
    if param_estim == true && eq_params != SciMLBase.NullParameters()
        param_len = length(eq_params)
        last_indx =  [0;accumulate(+, length.(init??))][end]
        params_symbols = Symbol[]
        expr_params = Expr[]
        for (i,eq_param) in enumerate(eq_params)
            push!(expr_params, :($??[$(i+last_indx:i+last_indx)]))
            push!(params_symbols, Symbol(:($eq_param)))
        end
        params_eq = Expr(:(=), build_expr(:tuple, params_symbols), build_expr(:tuple, expr_params))
        push!(ex.args,  params_eq)
    end

    if eq_params != SciMLBase.NullParameters() && param_estim == false
        params_symbols = Symbol[]
        expr_params = Expr[]
        for (i , eq_param) in enumerate(eq_params)
            push!(expr_params, :(ArrayInterface.allowed_getindex(p,$i:$i)))
            push!(params_symbols, Symbol(:($eq_param)))
        end
        params_eq = Expr(:(=), build_expr(:tuple, params_symbols), build_expr(:tuple, expr_params))
        push!(ex.args,  params_eq)
    end

    eq_pair_expr = Expr[]
    for i in keys(this_eq_pair)
        push!(eq_pair_expr, :( $(Symbol(:cord, :($i))) = vcat($(this_eq_pair[i]...))))
    end
    vcat_expr = Expr(:block, :($(eq_pair_expr...)))
    vcat_expr_loss_functions = Expr(:block, vcat_expr, loss_function) # TODO rename

    if strategy isa QuadratureTraining
        indvars_ex = get_indvars_ex(bc_indvars)
        left_arg_pairs, right_arg_pairs = this_eq_indvars, indvars_ex 
        vars_eq = Expr(:(=), build_expr(:tuple, left_arg_pairs), build_expr(:tuple, right_arg_pairs))
    else
        indvars_ex = [:($:cord[[$i],:]) for (i, u) ??? enumerate(this_eq_indvars)]
        left_arg_pairs, right_arg_pairs = this_eq_indvars, indvars_ex
        vars_eq = Expr(:(=), build_expr(:tuple, left_arg_pairs), build_expr(:tuple, right_arg_pairs))
    end

    let_ex = Expr(:let, vars_eq, vcat_expr_loss_functions)
    push!(ex.args,  let_ex)

    expr_loss_function = :(($vars) -> begin $ex end)
end

function build_loss_function(eqs,_indvars,_depvars,phi,derivative,integral,
                             chain,init??,strategy;
                             bc_indvars=nothing,
                             eq_params=SciMLBase.NullParameters(),
                             param_estim=false,
                             default_p=nothing)
    # dictionaries: variable -> unique number
    depvars,indvars,dict_indvars,dict_depvars, dict_depvar_input = get_vars(_indvars, _depvars)
    bc_indvars = bc_indvars==nothing ? indvars : bc_indvars
    return build_loss_function(eqs,indvars,depvars,
                               dict_indvars,dict_depvars,dict_depvar_input,
                               phi,derivative,integral,chain,init??,strategy;
                               bc_indvars=bc_indvars,
                               integration_indvars=indvars,
                               eq_params=eq_params,
                               param_estim=param_estim,
                               default_p=default_p)
end

function build_loss_function(eqs,indvars,depvars,
                             dict_indvars,dict_depvars,dict_depvar_input,
                             phi,derivative,integral,chain,init??,strategy;
                             bc_indvars = indvars,
                             integration_indvars=indvars,
                             eq_params=SciMLBase.NullParameters(),
                             param_estim=false,
                             default_p=nothing)
     expr_loss_function = build_symbolic_loss_function(eqs,indvars,depvars,
                                                       dict_indvars,dict_depvars, dict_depvar_input,
                                                       phi,derivative,integral,chain,init??,strategy;
                                                       bc_indvars = bc_indvars,integration_indvars=integration_indvars,
                                                       eq_params = eq_params,
                                                       param_estim=param_estim,default_p=default_p)
    u = get_u()
    _loss_function = @RuntimeGeneratedFunction(expr_loss_function)
    loss_function = (cord, ??) -> begin
        _loss_function(cord, ??, phi, derivative, integral, u, default_p)
    end
    return loss_function
end

function get_vars(indvars_, depvars_)
    indvars = ModelingToolkit.getname.(indvars_)
    depvars = Symbol[]
    dict_depvar_input = Dict{Symbol,Vector{Symbol}}()
    for d in depvars_
        if ModelingToolkit.value(d) isa Term
            dname = ModelingToolkit.getname(d)
            push!(depvars, dname)
            push!(dict_depvar_input, dname => [nameof(ModelingToolkit.value(argument)) for argument in ModelingToolkit.value(d).arguments])
        else
            dname = ModelingToolkit.getname(d)
            push!(depvars, dname)
            push!(dict_depvar_input, dname => indvars) # default to all inputs if not given
        end
     end
    dict_indvars = get_dict_vars(indvars)
    dict_depvars = get_dict_vars(depvars)
    return depvars, indvars, dict_indvars, dict_depvars, dict_depvar_input
end

function get_integration_variables(eqs, _indvars::Array, _depvars::Array)
    depvars, indvars, dict_indvars, dict_depvars, dict_depvar_input = get_vars(_indvars, _depvars)
    get_integration_variables(eqs, dict_indvars, dict_depvars)
end

function get_integration_variables(eqs, dict_indvars, dict_depvars)
    exprs = toexpr.(eqs)
    vars = map(exprs) do expr
        _vars =  Symbol.(filter(indvar -> length(find_thing_in_expr(expr,  indvar)) > 0, sort(collect(keys(dict_indvars)))))
    end
end

function get_variables(eqs, _indvars::Array, _depvars::Array)
    depvars, indvars, dict_indvars, dict_depvars, dict_depvar_input = get_vars(_indvars, _depvars)
    return get_variables(eqs, dict_indvars, dict_depvars)
end

function get_variables(eqs,dict_indvars,dict_depvars)
    bc_args = get_argument(eqs,dict_indvars,dict_depvars)
    return map(barg -> filter(x -> x isa Symbol, barg), bc_args)
end

function get_number(eqs,dict_indvars,dict_depvars)
    bc_args = get_argument(eqs,dict_indvars,dict_depvars)
    return map(barg -> filter(x -> x isa Number, barg), bc_args)
end

function find_thing_in_expr(ex::Expr, thing; ans = [])
    if thing in ex.args
        push!(ans,ex)
    end
    for e in ex.args
        if e isa Expr
            if thing in e.args
                push!(ans,e)
            end
            find_thing_in_expr(e,thing; ans=ans)
        end
    end
    return collect(Set(ans))
end

# Get arguments from boundary condition functions
function get_argument(eqs,_indvars::Array,_depvars::Array)
    depvars,indvars,dict_indvars,dict_depvars, dict_depvar_input = get_vars(_indvars, _depvars)
    get_argument(eqs,dict_indvars,dict_depvars)
end
function get_argument(eqs,dict_indvars,dict_depvars)
    exprs = toexpr.(eqs)
    vars = map(exprs) do expr
        _vars =  map(depvar -> find_thing_in_expr(expr,  depvar), collect(keys(dict_depvars)))
        f_vars = filter(x -> !isempty(x), _vars)
        map(x -> first(x), f_vars)
    end
    args_ = map(vars) do _vars
        ind_args_ = map(var -> var.args[2:end], _vars)
        syms = Set{Symbol}()
        filter(vcat(ind_args_...)) do ind_arg
            if ind_arg isa Symbol
                if ind_arg ??? syms
                    false
                else
                    push!(syms, ind_arg)
                    true
                end
            else
                true
            end
        end
    end
    return args_ # TODO for all arguments
end


function generate_training_sets(domains,dx,eqs,bcs,eltype??,_indvars::Array,_depvars::Array)
    depvars,indvars,dict_indvars,dict_depvars, dict_depvar_input = get_vars(_indvars, _depvars)
    return generate_training_sets(domains,dx,eqs,bcs,eltype??,dict_indvars,dict_depvars)
end
# Generate training set in the domain and on the boundary
function generate_training_sets(domains,dx,eqs,bcs,eltype??,dict_indvars::Dict,dict_depvars::Dict)
    if dx isa Array
        dxs = dx
    else
        dxs = fill(dx,length(domains))
    end

    spans = [infimum(d.domain):dx:supremum(d.domain) for (d,dx) in zip(domains,dxs)]
    dict_var_span = Dict([Symbol(d.variables) => infimum(d.domain):dx:supremum(d.domain) for (d,dx) in zip(domains,dxs)])

    bound_args = get_argument(bcs,dict_indvars,dict_depvars)
    bound_vars = get_variables(bcs,dict_indvars,dict_depvars)

    dif = [eltype??[] for i=1:size(domains)[1]]
    for _args in bound_args
        for (i,x) in enumerate(_args)
            if x isa Number
                push!(dif[i],x)
            end
        end
    end
    cord_train_set = collect.(spans)
    bc_data = map(zip(dif,cord_train_set)) do (d,c)
        setdiff(c, d)
    end

    dict_var_span_ = Dict([Symbol(d.variables) => bc for (d,bc) in zip(domains,bc_data)])

    bcs_train_sets = map(bound_args) do bt
        span = map(b -> get(dict_var_span, b, b), bt)
        _set = adapt(eltype??,hcat(vec(map(points -> collect(points), Iterators.product(span...)))...))
    end

    pde_vars = get_variables(eqs,dict_indvars,dict_depvars)
    pde_args = get_argument(eqs,dict_indvars,dict_depvars)

    pde_train_set = adapt(eltype??, hcat(vec(map(points -> collect(points), Iterators.product(bc_data...)))...))

    pde_train_sets = map(pde_args) do bt
        span = map(b -> get(dict_var_span_, b, b), bt)
        _set = adapt(eltype??,hcat(vec(map(points -> collect(points), Iterators.product(span...)))...))
    end
    [pde_train_sets,bcs_train_sets]
end

function get_bounds(domains,eqs,bcs,eltype??,_indvars::Array,_depvars::Array,strategy)
    depvars,indvars,dict_indvars,dict_depvars,dict_depvar_input = get_vars(_indvars, _depvars)
    return get_bounds(domains,eqs,bcs,eltype??,dict_indvars,dict_depvars,strategy)
end

function get_bounds(domains,eqs,bcs,eltype??,_indvars::Array,_depvars::Array,strategy::QuadratureTraining)
    depvars,indvars,dict_indvars,dict_depvars,dict_depvar_input = get_vars(_indvars, _depvars)
    return get_bounds(domains,eqs,bcs,eltype??,dict_indvars,dict_depvars,strategy)
end

function get_bounds(domains,eqs,bcs,eltype??,dict_indvars,dict_depvars,strategy::QuadratureTraining)
    dict_lower_bound = Dict([Symbol(d.variables) => infimum(d.domain) for d in domains])
    dict_upper_bound = Dict([Symbol(d.variables) => supremum(d.domain) for d in domains])

    pde_args = get_argument(eqs,dict_indvars,dict_depvars)

    pde_lower_bounds= map(pde_args) do pd
        span = map(p -> get(dict_lower_bound, p, p), pd)
        map(s -> adapt(eltype??,s) + cbrt(eps(eltype??)), span)
    end
    pde_upper_bounds= map(pde_args) do pd
        span = map(p -> get(dict_upper_bound, p, p), pd)
        map(s -> adapt(eltype??,s) - cbrt(eps(eltype??)), span)
    end
    pde_bounds= [pde_lower_bounds,pde_upper_bounds]

    bound_vars = get_variables(bcs,dict_indvars,dict_depvars)

    bcs_lower_bounds = map(bound_vars) do bt
        map(b -> dict_lower_bound[b], bt)
    end
    bcs_upper_bounds = map(bound_vars) do bt
        map(b -> dict_upper_bound[b], bt)
    end
    bcs_bounds= [bcs_lower_bounds,bcs_upper_bounds]

    [pde_bounds, bcs_bounds]
end

function get_bounds(domains,eqs,bcs,eltype??,dict_indvars,dict_depvars,strategy)
    dx = 1 / strategy.points
    dict_span = Dict([Symbol(d.variables) => [infimum(d.domain)+dx, supremum(d.domain)-dx] for d in domains])
    # pde_bounds = [[infimum(d.domain),supremum(d.domain)] for d in domains]
    pde_args = get_argument(eqs,dict_indvars,dict_depvars)

    pde_bounds= map(pde_args) do pd
        span = map(p -> get(dict_span, p, p), pd)
        map(s -> adapt(eltype??,s), span)
    end

    bound_args = get_argument(bcs,dict_indvars,dict_depvars)
    dict_span = Dict([Symbol(d.variables) => [infimum(d.domain), supremum(d.domain)] for d in domains])

    bcs_bounds= map(bound_args) do bt
        span = map(b -> get(dict_span, b, b), bt)
        map(s -> adapt(eltype??,s), span)
    end
    [pde_bounds,bcs_bounds]
end

function get_phi(chain,parameterless_type_??)
    # The phi trial solution
    if chain isa FastChain
        phi = (x,??) -> chain(adapt(parameterless_type_??,x),??)
    else
        _,re  = Flux.destructure(chain)
        phi = (x,??) -> re(??)(adapt(parameterless_type_??,x))
    end
    phi
end

function get_u()
    u = (cord, ??, phi)-> phi(cord, ??)
end


# the method to calculate the derivative
function get_numeric_derivative()
    derivative =
        (phi,u,x,??s,order,??) ->
        begin
            _epsilon = one(eltype(??)) / (2*cbrt(eps(eltype(??))))
            ?? = ??s[order]
            ?? = adapt(DiffEqBase.parameterless_type(??),??)
            x = adapt(DiffEqBase.parameterless_type(??),x)
            if order > 1
                return (derivative(phi,u,x .+ ??,??s,order-1,??)
                      .- derivative(phi,u,x .- ??,??s,order-1,??)) .* _epsilon
            else
                return (u(x .+ ??,??,phi) .- u(x .- ??,??,phi)) .* _epsilon
            end
        end
end

function get_numeric_integral(strategy, _indvars, _depvars, chain, derivative)
    depvars,indvars,dict_indvars,dict_depvars = get_vars(_indvars, _depvars)
    integral =
        (u, cord, phi, integrating_var_id, integrand_func, lb, ub, ?? ;strategy=strategy, indvars=indvars, depvars=depvars, dict_indvars=dict_indvars, dict_depvars=dict_depvars)->
            begin
                
                function integration_(cord, lb, ub, ??)
                    cord_ = cord
                    function integrand_(x , p)
                        @Zygote.ignore @views(cord_[integrating_var_id]) .= x
                        return integrand_func(cord_, p, phi, derivative, nothing, u, nothing)
                    end
                    prob_ = QuadratureProblem(integrand_,lb, ub ,??)
                    sol = solve(prob_,CubatureJLh(),reltol=1e-3,abstol=1e-3)[1]
                    return sol
                end

                lb_ = zeros(size(lb)[1], size(cord)[2])
                ub_ = zeros(size(ub)[1], size(cord)[2])
                for (i, l) in enumerate(lb)
                    if l isa Number
                        @Zygote.ignore lb_[i, :] = fill(l, 1, size(cord)[2])
                    else
                        @Zygote.ignore lb_[i, :] = l(cord , ??, phi, derivative, nothing, u, nothing)
                    end
                end
                for (i, u_) in enumerate(ub)
                    if u_ isa Number
                        @Zygote.ignore ub_[i, :] = fill(u_, 1, size(cord)[2])
                    else
                        @Zygote.ignore ub_[i, :] = u_(cord , ??, phi, derivative, nothing, u, nothing)
                    end
                end
                integration_arr = Matrix{Float64}(undef, 1, 0)
                for i in 1:size(cord)[2]
                    # ub__ = @Zygote.ignore getindex(ub_, :,  i)
                    # lb__ = @Zygote.ignore getindex(lb_, :,  i)
                    integration_arr = hcat(integration_arr ,integration_(cord[:, i], lb_[:, i], ub_[:, i], ??))
                end
                return integration_arr
            end
end

function get_loss_function(loss_function, train_set, eltype??,parameterless_type_??, strategy::GridTraining;??=nothing)
    loss = (??) -> mean(abs2,loss_function(train_set, ??))
end
            
@nograd function generate_random_points(points, bound, eltype??)
    function f(b)
      if b isa Number
           fill(eltype??(b),(1,points))
       else
           lb, ub =  b[1], b[2]
           lb .+ (ub .- lb) .* rand(eltype??,1,points)
       end
    end
    vcat(f.(bound)...)
end

function get_loss_function(loss_function, bound, eltype??, parameterless_type_??, strategy::StochasticTraining;??=nothing)
    points = strategy.points

    loss = (??) -> begin
        sets = generate_random_points(points, bound,eltype??)
        sets_ = adapt(parameterless_type_??,sets)
        mean(abs2,loss_function(sets_, ??))
    end
    return loss
end

@nograd function generate_quasi_random_points(points, bound, eltype??, sampling_alg)
    function f(b)
      if b isa Number
           fill(eltype??(b),(1,points))
       else
           lb, ub =  eltype??[b[1]], [b[2]]
           QuasiMonteCarlo.sample(points,lb,ub,sampling_alg)
       end
    end
    vcat(f.(bound)...)
end

function generate_quasi_random_points_batch(points, bound, eltype??, sampling_alg,minibatch)
    map(bound) do b
        if !(b isa Number)
            lb, ub =  [b[1]], [b[2]]
            set_ = QuasiMonteCarlo.generate_design_matrices(points,lb,ub,sampling_alg,minibatch)
            set = map(s -> adapt(eltype??,s), set_)
        else
            set = fill(eltype??(b),(1,points))
        end
    end
end

function get_loss_function(loss_function, bound, eltype??,parameterless_type_??,strategy::QuasiRandomTraining;??=nothing)
    sampling_alg = strategy.sampling_alg
    points = strategy.points
    resampling = strategy.resampling
    minibatch = strategy.minibatch

    point_batch = nothing
    point_batch = if resampling == false
        generate_quasi_random_points_batch(points, bound,eltype??,sampling_alg,minibatch)
    end
    loss =
        if resampling == true
            ?? -> begin
                sets = generate_quasi_random_points(points, bound, eltype??, sampling_alg)
                sets_ = adapt(parameterless_type_??,sets)
                mean(abs2,loss_function(sets_, ??))
            end
        else
            ?? -> begin
                sets =  [point_batch[i] isa Array{eltype??,2} ?
                         point_batch[i] : point_batch[i][rand(1:minibatch)]
                                            for i in 1:length(point_batch)] #TODO
                sets_ = vcat(sets...)
                sets__ = adapt(parameterless_type_??,sets_)
                mean(abs2,loss_function(sets__, ??))
            end
        end
    return loss
end

function get_loss_function(loss_function, lb,ub ,eltype??, parameterless_type_??,strategy::QuadratureTraining;??=nothing)

    if length(lb) == 0
        loss = (??) -> mean(abs2,loss_function(rand(eltype??,1,10), ??))
        return loss
    end
    area = eltype??(prod(abs.(ub .-lb)))
    f_ = (lb,ub,loss_,??) -> begin
        # last_x = 1
        function _loss(x,??)
            # last_x = x
            # mean(abs2,loss_(x,??), dims=2)
            # size_x = fill(size(x)[2],(1,1))
            x = adapt(parameterless_type_??,x)
            sum(abs2,loss_(x,??), dims=2) #./ size_x
        end
        prob = QuadratureProblem(_loss,lb,ub,??,batch = strategy.batch,nout=1)
        solve(prob,
              strategy.quadrature_alg,
              reltol = strategy.reltol,
              abstol = strategy.abstol,
              maxiters = strategy.maxiters)[1]
    end
    loss = (??) -> 1/area* f_(lb,ub,loss_function,??)
    return loss
end

function SciMLBase.symbolic_discretize(pde_system::PDESystem, discretization::PhysicsInformedNN)
    eqs = pde_system.eqs
    bcs = pde_system.bcs
    
    domains = pde_system.domain
    eq_params = pde_system.ps
    defaults = pde_system.defaults
    default_p = eq_params == SciMLBase.NullParameters() ? nothing : [defaults[ep] for ep in eq_params]

    param_estim = discretization.param_estim
    additional_loss = discretization.additional_loss

    # dimensionality of equation
    dim = length(domains)
    depvars,indvars,dict_indvars,dict_depvars,dict_depvar_input = get_vars(pde_system.indvars, pde_system.depvars)

    chain = discretization.chain
    init?? = discretization.init_params
    flat_init?? = if (typeof(chain) <: AbstractVector) reduce(vcat,init??) else init?? end
    eltype?? = eltype(flat_init??)
    parameterless_type_?? =  DiffEqBase.parameterless_type(flat_init??)
    phi = discretization.phi
    derivative = discretization.derivative
    strategy = discretization.strategy
    integral = get_numeric_integral(strategy, pde_system.indvars, pde_system.depvars, chain, derivative)
    if !(eqs isa Array)
        eqs = [eqs]
    end
    pde_indvars = if strategy isa QuadratureTraining 
        get_argument(eqs,dict_indvars,dict_depvars)
    else
        get_variables(eqs,dict_indvars,dict_depvars)
    end
    pde_integration_vars = get_integration_variables(eqs,dict_indvars,dict_depvars)

    symbolic_pde_loss_functions = [build_symbolic_loss_function(eq,indvars,depvars,
                                                                dict_indvars,dict_depvars,dict_depvar_input,
                                                                phi, derivative,integral, chain,init??,strategy;eq_params=eq_params,param_estim=param_estim,default_p=default_p,
                                                                bc_indvars=pde_indvar, integration_indvars=integration_indvar
                                                                ) for (eq, pde_indvar, integration_indvar) in zip(eqs, pde_indvars, pde_integration_vars)]

    bc_indvars = if strategy isa QuadratureTraining
         get_argument(bcs,dict_indvars,dict_depvars)
    else
         get_variables(bcs,dict_indvars,dict_depvars)
    end
    bc_integration_vars = get_integration_variables(bcs, dict_indvars, dict_depvars)
    symbolic_bc_loss_functions = [build_symbolic_loss_function(bc,indvars,depvars,
                                                               dict_indvars,dict_depvars, dict_depvar_input,
                                                               phi, derivative,integral,chain,init??,strategy,
                                                               eq_params=eq_params,
                                                               param_estim=param_estim,
                                                               default_p=default_p;
                                                               bc_indvars=bc_indvar,
                                                               integration_indvars=integration_indvar)
                                                               for (bc, bc_indvar, integration_indvar) in zip(bcs, bc_indvars, bc_integration_vars)]
    symbolic_pde_loss_functions, symbolic_bc_loss_functions
end

# Convert a PDE problem into an OptimizationProblem
function SciMLBase.discretize(pde_system::PDESystem, discretization::PhysicsInformedNN)
    eqs = pde_system.eqs
    bcs = pde_system.bcs

    domains = pde_system.domain
    eq_params = pde_system.ps
    defaults = pde_system.defaults
    default_p = eq_params == SciMLBase.NullParameters() ? nothing : [defaults[ep] for ep in eq_params]

    param_estim = discretization.param_estim
    additional_loss = discretization.additional_loss
    
    # dimensionality of equation
    dim = length(domains)

    #TODO fix it in MTK 6.0.0+v: ModelingToolkit.get_ivs(pde_system)
     depvars,indvars,dict_indvars,dict_depvars, dict_depvar_input = get_vars(pde_system.ivs,
                                                         pde_system.dvs)

    chain = discretization.chain
    init?? = discretization.init_params
    flat_init?? = if (typeof(chain) <: AbstractVector) reduce(vcat,init??) else  init?? end
    eltype?? = eltype(flat_init??)
    parameterless_type_?? =  DiffEqBase.parameterless_type(flat_init??)

    flat_init?? = if param_estim == false flat_init?? else vcat(flat_init??, adapt(typeof(flat_init??),default_p)) end
    phi = discretization.phi
    derivative = discretization.derivative
    strategy = discretization.strategy
    integral = get_numeric_integral(strategy, pde_system.indvars, pde_system.depvars, chain, derivative)
    if !(eqs isa Array)
        eqs = [eqs]
    end
    pde_indvars = if strategy isa QuadratureTraining
        get_argument(eqs,dict_indvars,dict_depvars)
    else
        get_variables(eqs,dict_indvars,dict_depvars)
    end
   pde_integration_vars = get_integration_variables(eqs, dict_indvars, dict_depvars)
   _pde_loss_functions = [build_loss_function(eq,indvars,depvars,
                                             dict_indvars,dict_depvars,dict_depvar_input,
                                             phi, derivative,integral, chain, init??,strategy,eq_params=eq_params,param_estim=param_estim,default_p=default_p,
                                             bc_indvars=pde_indvar, integration_indvars=integration_indvar
                                             ) for (eq, pde_indvar, integration_indvar) in zip(eqs, pde_indvars, pde_integration_vars)]
    bc_indvars = if strategy isa QuadratureTraining
         get_argument(bcs,dict_indvars,dict_depvars)
    else
         get_variables(bcs,dict_indvars,dict_depvars)
    end
    bc_integration_vars = get_integration_variables(bcs, dict_indvars, dict_depvars)

    _bc_loss_functions = [build_loss_function(bc,indvars,depvars,
                                              dict_indvars,dict_depvars, dict_depvar_input,
                                              phi,derivative,integral,chain,init??,strategy;
                                              eq_params=eq_params,
                                              param_estim=param_estim,
                                              default_p=default_p,
                                              bc_indvars=bc_indvar,
                                              integration_indvars=integration_indvar) for (bc, bc_indvar, integration_indvar) in zip(bcs, bc_indvars, bc_integration_vars)]

    pde_loss_functions, bc_loss_functions =
    if strategy isa GridTraining
        dx = strategy.dx

        train_sets = generate_training_sets(domains,dx,eqs,bcs,eltype??,
                                            dict_indvars,dict_depvars)

        # the points in the domain and on the boundary
        pde_train_sets, bcs_train_sets = train_sets
        pde_train_sets = adapt.(parameterless_type_??,pde_train_sets)
        bcs_train_sets =  adapt.(parameterless_type_??,bcs_train_sets)
        pde_loss_functions = [get_loss_function(_loss,_set,eltype??,parameterless_type_??,strategy)
                                                 for (_loss,_set) in zip(_pde_loss_functions,pde_train_sets)]

        bc_loss_functions =  [get_loss_function(_loss,_set,eltype??,parameterless_type_??,strategy)
                                                 for (_loss,_set) in zip(_bc_loss_functions, bcs_train_sets)]
        (pde_loss_functions, bc_loss_functions)
    elseif strategy isa StochasticTraining
         bounds = get_bounds(domains,eqs,bcs,eltype??,dict_indvars,dict_depvars,strategy)
         pde_bounds, bcs_bounds = bounds

         pde_loss_functions = [get_loss_function(_loss,bound,eltype??,parameterless_type_??,strategy)
                                                 for (_loss,bound) in zip(_pde_loss_functions, pde_bounds)]

          bc_loss_functions = [get_loss_function(_loss,bound,eltype??,parameterless_type_??,strategy) 
                                                 for (_loss, bound) in zip(_bc_loss_functions, bcs_bounds)]
          (pde_loss_functions, bc_loss_functions)
    elseif strategy isa QuasiRandomTraining
         bounds = get_bounds(domains,eqs,bcs,eltype??,dict_indvars,dict_depvars,strategy)
         pde_bounds, bcs_bounds = bounds

         pde_loss_functions = [get_loss_function(_loss,bound,eltype??,parameterless_type_??,strategy)
                                                  for (_loss,bound) in zip(_pde_loss_functions, pde_bounds)]

         strategy_ = QuasiRandomTraining(strategy.bcs_points;
                                         sampling_alg = strategy.sampling_alg,
                                         resampling = strategy.resampling,
                                         minibatch = strategy.minibatch)
         bc_loss_functions = [get_loss_function(_loss,bound,eltype??,parameterless_type_??,strategy_)
                                                for (_loss, bound) in zip(_bc_loss_functions, bcs_bounds)]
         (pde_loss_functions, bc_loss_functions)
    elseif strategy isa QuadratureTraining
        bounds = get_bounds(domains,eqs,bcs,eltype??,dict_indvars,dict_depvars,strategy)
        pde_bounds, bcs_bounds = bounds

        lbs,ubs = pde_bounds
        pde_loss_functions = [get_loss_function(_loss,lb,ub,eltype??,parameterless_type_??,strategy)
                                                 for (_loss,lb,ub) in zip(_pde_loss_functions, lbs,ubs )]
        lbs,ubs = bcs_bounds
        bc_loss_functions = [get_loss_function(_loss,lb,ub,eltype??,parameterless_type_??,strategy)
                                                for (_loss,lb,ub) in zip(_bc_loss_functions, lbs,ubs)]

        (pde_loss_functions, bc_loss_functions)
    end

    pde_loss_function = ?? -> sum(map(l->l(??) ,pde_loss_functions))
    bcs_loss_function = ?? -> sum(map(l->l(??) ,bc_loss_functions))
    loss_function = ?? -> pde_loss_function(??) + bcs_loss_function(??)

    function loss_function_(??,p)
        if additional_loss isa Nothing
            return loss_function(??)
        else
            function _additional_loss(phi,??)
                (??_,p_) = if (param_estim == true)
                    ??[1:end - length(default_p)], ??[(end - length(default_p) + 1):end]
                else
                    ??, nothing
                end
                return additional_loss(phi, ??, p_)
            end
            return loss_function(??) + _additional_loss(phi, ??)
        end
end

    f = OptimizationFunction(loss_function_, GalacticOptim.AutoZygote())
    GalacticOptim.OptimizationProblem(f, flat_init??)
end
