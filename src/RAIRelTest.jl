module RAIRelTest

VERSION = "0.1.0"

include("config.jl")
include("helpers.jl")
include("api.jl")
include("cli.jl")

# configs
export Config,
    load_config,
    session_config,
    set_session_engine!,
    set_session_context!,
    unset_session_engine!

# API
export test_packages,
    test_package,
    run_package_testitems,
    run_package_suites,
    run_suite,
    run_test,
    run_testitems,
    run_script,
    prepare_package,
    prepare_suite,
    prepare_for_test,
    install_package

# test engine pool
export start_pool, stop_pool, with_pool

end # module RAIRelTest
