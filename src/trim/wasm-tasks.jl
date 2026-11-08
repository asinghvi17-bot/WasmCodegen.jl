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
    # `asyncmap` without `batch_size`: typed (Base's collects its results from `Ref{Any}`s, or
    # from a `Vector{Any}` and an `AsyncCollector` of untyped fields); with one, Base's own.
    # Which function that is depends on Base: 1.12's `async_usemap` (asyncmap.jl:80), which
    # `asyncmap` calls; 1.13 has none, its `asyncmap` (asyncmap.jl:76) itself runs the
    # `AsyncCollector`
    @static if VERSION >= v"1.13-"
        @eval Base function asyncmap(f, c...; ntasks=0, batch_size=nothing)
            batch_size = verify_batch_size(batch_size)
            batch_size === nothing &&
                return $(T.asyncmap_typed)(f, verify_ntasks(enumerate(zip(c...)), ntasks), c...)
            # (Base's, asyncmap.jl:77-93)
            src = isone(length(c)) ? c[1] : zip(c...)
            if haslength(src)
                n = length(src)
                results = Vector{Any}(undef, n)
            else
                results = Dict{Int,Any}()
            end
            foreach(identity, AsyncCollector(f, results, c...; ntasks=ntasks, batch_size=batch_size))
            if results isa Dict
                v = Any[results[i] for i in 1:length(results)]
            else
                v = results
            end
            return _asyncmap_result(v, src)
        end
    else
        @eval Base function async_usemap(f, c...; ntasks=0, batch_size=nothing)
            ntasks = verify_ntasks(c[1], ntasks)
            batch_size = verify_batch_size(batch_size)
            batch_size === nothing && return $(T.asyncmap_typed)(f, ntasks, c...)
            exec_func = batch -> begin
                # extract the Refs from the input tuple
                batch_refs = map(x->x[1], batch)

                # and the args tuple....
                batched_args = map(x->x[2], batch)

                results = f(batched_args)
                foreach(x -> (batch_refs[x[1]].x = x[2]), enumerate(results))
            end
            chnl, worker_tasks = setup_chnl_and_tasks(exec_func, ntasks, batch_size)
            return wrap_n_exec_twice(chnl, worker_tasks, ntasks, exec_func, c...)
        end
    end
end
