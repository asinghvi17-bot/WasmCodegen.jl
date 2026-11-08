# Julia Tasks on JSPI stacks (`Config(tasks = :jspi)`): the C runtime's scheduler
# primitives on one thread (`Runtime.Tasks`). Base's own `schedule`, `yield`, `yieldto`,
# `Condition`, `Channel`, `Event`, `fetch` and `timedwait` run unchanged on top. Applied
# after juliac's trim patches, in place of the code generator's stubs for a program of one task.
#
# Each patch calls a runtime function (`Runtime.Tasks`): natively Base's original method, in
# Wasm a method of `WASM_METHODS`, the runtime's. The patches are defined in the latest world,
# which is also where libuv's callbacks run in the compiler's process (a process exit schedules
# its waiter): those must keep Base's scheduler.

let T = WasmCodegen.Runtime.Tasks
    # `jl_new_task`, specialized on the closure (its body is called without dispatch)
    @eval Core Task(f::F) where {F} = $(T.task)(f)
    @eval Core Task(f::F, reserved_stack::Int) where {F} = $(T.task)(f)
    @eval Base enq_work(t::Task) = $(T.enq_work)(t)
    @eval Base ensure_rescheduled(othertask::Task) = $(T.ensure_rescheduled)(othertask)
    @eval Base try_yieldto(undo) = $(T.try_yieldto)(undo)
    @eval Base wait() = $(T.wait)()
    @eval Base istaskstarted(t::Task) = $(T.istaskstarted)(t)
    # libuv's timers: `julia_io` timers polled by the scheduler
    @eval Base Timer(timeout::Real; interval::Real=0.0) = $(T.timer)(timeout, interval)
    @eval Base Timer(cb::F, timeout::Real; spawn::Union{Nothing,Bool}=nothing, interval::Real=0.0) where {F<:Function} =
        $(T.timer_cb)(cb, timeout, spawn, interval)
    @eval Base _trywait(t::Timer) = $(T.trywait)(t)
    @eval Base close(t::Timer) = $(T.close)(t)
    # (untyped: a dynamic `display_error`; a dynamic `wait` of what `@sync` collected)
    @eval Base errormonitor(t::Task) = $(T.errormonitor)(t)
    @eval Base sync_end(c::Channel{Any}) = $(T.sync_end)(c)
    # the runtime's host waits as tasks' waits; `sleep` on a `Timer`, as Base's
    @eval WasmCodegen.Runtime.Host await_handle(h::Int32) = $(T.await)(h)
    @eval WasmCodegen.Runtime.Host sleep_ms(ms::UInt64) = $(T.sleep_ms)(ms)
    # (a constant of the compilation, for packages: the module has tasks)
    @eval WasmCodegen.Runtime.Tasks enabled() = true
    # `asyncmap` and `asyncmap!`: typed (Base's collect their results from `Ref{Any}`s, or from
    # a `Vector{Any}` and an `AsyncCollector` of untyped fields; with a `batch_size`, from
    # `Vector{Any}` batches). Which function runs the workers depends on Base: 1.12's
    # `async_usemap` (asyncmap.jl:80), which `asyncmap` calls, and that of a `BitArray`; 1.13
    # has none, its `asyncmap` (asyncmap.jl:76) itself runs the `AsyncCollector`. `asyncmap!`
    # is that of a string, on both
    @static if VERSION >= v"1.13-"
        @eval Base asyncmap(f, c...; ntasks=0, batch_size=nothing) =
            $(T.asyncmap_typed)(f, verify_ntasks(enumerate(zip(c...)), ntasks), verify_batch_size(batch_size), c...)
    else
        @eval Base async_usemap(f, c...; ntasks=0, batch_size=nothing) =
            $(T.asyncmap_typed)(f, verify_ntasks(c[1], ntasks), verify_batch_size(batch_size), c...)
    end
    @eval Base asyncmap!(f, r, c1, c...; ntasks=0, batch_size=nothing) =
        $(T.asyncmap_typed!)(f, r, verify_ntasks(enumerate(zip(c1, c...)), ntasks), verify_batch_size(batch_size), c1, c...)
end
