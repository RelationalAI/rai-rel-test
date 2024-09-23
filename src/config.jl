
import RAI
import RAITest

"""
A container of configuration passed around most commands.
"""
struct Config
    # RAI.Context with configuration to access a RAI REST API. If empty, the command will
    # load a config with `load_config()`.
    context::Union{RAI.Context,Nothing}
    # The RAI engine to use for the operation. If empty, assume we can grab one from
    # the test engine pool (must be managed with `start_pool!` and `stop_pool!`.
    engine::Union{String,Nothing}
end

"""
Extract a `RAI.Context` from this config and fallback to loading the default context.
"""
function get_some_context(config::Config)
    or_else(config.context) do
        return load_context("default")
    end
end

"""
A global variable that can be used to set up configuration for the REPL session. This will
take precedence over env variables, but will be overridden by explicit arguments to commands.
"""
session_config = Config(nothing, nothing)

"""
Set the `engine` field on the `session_config`.
"""
function set_session_engine!(engine::AbstractString)
    return global session_config = Config(session_config.context, engine)
end

"""
Unset the `engine` field on the `session_config`.
"""
function unset_session_engine!()
    return global session_config = Config(session_config.context, nothing)
end

"""
Set the `context` field on the `session_config`, falling back to loading the default.
"""
function set_session_context!(profile::Union{AbstractString,Nothing})
    ctx = load_context(something(profile, "default"))
    return global session_config = Config(ctx, session_config.engine)
end

"""
Load a config object with using settings from session and env.
"""
function load_config()
    return load_config(Dict{Symbol,Any}())
end

"""
Load a config object, cascading the search for values across various sources.

Search order:
  1. the values in `args` (usually from the cli)
  2. session config (the values in the global `session_config` var)
  3. env variables
  4. default value, depending on the key (nothing for :engine, "default" profile to create
    a RAIContext)
"""
function load_config(args::Dict{Symbol,Any})
    ctx = get!(args, :context) do
        return get_some_context(session_config)
    end
    engine = get!(args, :engine) do
        return or_else(session_config.engine, get(ENV, "RAI_ENGINE", nothing))
    end
    return Config(ctx, engine)
end

"""
Load a context object from the `.rai/config` file, using this profile.
"""
function load_context(profile::AbstractString)
    return RAI.Context(RAI.load_config(profile=profile))
end

"""
Return `x` if it is a `T`. If it is a `Nothing`, return the result of calling the function.

This is similar to `something()` but the default value is computed lazily.
"""
or_else(default::Function, x::Union{T,Nothing}) where {T} = isnothing(x) ? default() : x

"""
Return `x` if it is a `T`, or else return `y`.

This is similar to `something()` but will not fail if `y` is `nothing`.
"""
or_else(x::Union{T,Nothing}, y::Union{T,Nothing}) where {T} = isnothing(x) ? y : x
