export @metal

macro metal(ex...)
    call = ex[end]
    kwargs = ex[1:end-1]

    # destructure the kernel call
    Meta.isexpr(call, :call) || throw(ArgumentError("second argument to @metal should be a function call"))
    f = call.args[1]
    args = call.args[2:end]

    @info "Kernel " f args
    code = quote end
    vars, var_exprs = assign_args!(code, args)

    # group keyword argument
    macro_kwargs, compiler_kwargs, call_kwargs, other_kwargs =
        split_kwargs(kwargs, [:launch], [:name], [:groups, :items, :queue])
    if !isempty(other_kwargs)
        key,val = first(other_kwargs).args
        throw(ArgumentError("Unsupported keyword argument '$key'"))
    end

    # handle keyword arguments that influence the macro's behavior
    launch = true
    for kwarg in macro_kwargs
        key,val = kwarg.args
        if key == :launch
            isa(val, Bool) || throw(ArgumentError("`launch` keyword argument to @cuda should be a constant value"))
            launch = val::Bool
        else
            throw(ArgumentError("Unsupported keyword argument '$key'"))
        end
    end
    if !launch && !isempty(call_kwargs)
        error("@metal with launch=false does not support launch-time keyword arguments; use them when calling the kernel")
    end

    # FIXME: macro hygiene wrt. escaping kwarg values (this broke with 1.5)
    #        we esc() the whole thing now, necessitating gensyms...
    @gensym f_var kernel_f kernel_args kernel_tt kernel

    # convert the arguments, call the compiler and launch the kernel
    # while keeping the original arguments alive
    push!(code.args,
        quote
            $f_var = $f
            GC.@preserve $(vars...) $f_var begin
                local $kernel_f = $mtlconvert($f_var)
                local $kernel_args = map($mtlconvert, ($(var_exprs...),))
                local $kernel_tt = Tuple{map(Core.Typeof, $kernel_args)...}
                local $kernel = $mtlfunction($kernel_f, $kernel_tt; $(compiler_kwargs...))
                if $launch
                    $kernel($(var_exprs...); $(call_kwargs...))
                end
                $kernel
            end
         end)
    return esc(code)
end

struct MetalCompilerParams <: GPUCompiler.AbstractCompilerParams end
GPUCompiler.runtime_module(::CompilerJob{<:Any,MetalCompilerParams}) = Metal

abstract type AbstractKernel{F,TT} end

@generated function call(kernel::AbstractKernel{F,TT}, args...; call_kwargs...) where {F,TT}
    sig = Base.signature_type(F, TT)
    args = (:F, (:( args[$i] ) for i in 1:length(args))...)

    # filter out ghost arguments that shouldn't be passed
    predicate = if VERSION >= v"1.5.0-DEV.581"
        dt -> isghosttype(dt) || Core.Compiler.isconstType(dt)
    else
        dt -> isghosttype(dt)
    end
    to_pass = map(!predicate, sig.parameters)
    call_t =                  Type[x[1] for x in zip(sig.parameters,  to_pass) if x[2]]
    call_args = Union{Expr,Symbol}[x[1] for x in zip(args, to_pass)            if x[2]]

    # replace non-isbits arguments (they should be unused, or compilation would have failed)
    for (i,dt) in enumerate(call_t)
        if !isbitstype(dt)
            call_t[i] = Ptr{Any}
            call_args[i] = :C_NULL
        end
    end

    # finalize types
    call_tt = Base.to_tuple_type(call_t)

    quote
        Base.@_inline_meta

        mtlcall(kernel.fun, $call_tt, $(call_args...); call_kwargs...)
    end
end

# Why is this all necessary? MtlFunction has the lib and function handle. Device doesn't? matter
struct MtlKernel{F,TT} <: AbstractKernel{F, TT}
    device::MtlDevice
    mod::MtlLibrary
    fun::MtlFunction
end

# ## host-side kernels

# struct HostKernel{F,TT} <: AbstractKernel{F,TT}
#     fun::MtlKernel
# end

## host-side API

function mtlfunction(f::Core.Function, tt::Type=Tuple{}; name=nothing, kwargs...)
    dev = MtlDevice(1)
    source = FunctionSpec(f, tt, true, name)
    target = MetalCompilerTarget(; kwargs...)
    params = MetalCompilerParams()
    job = CompilerJob(target, source, params)
    metallib_path, entry = mtlfunction_compile(job)
    lib = MtlLibraryFromFile(dev, metallib_path)
    fun = MtlFunction(lib, entry)
    return MtlKernel{job.source.f,job.source.tt}(dev, lib, fun)
end


function mtlfunction_compile(@nospecialize(job::CompilerJob))
    metallib_path = "test.metallib"
    # FIXME: Remove from here and ensure LLVM does this properly
    LLVM.InitializeMetalTarget()
    LLVM.InitializeMetalTargetMC()
    LLVM.InitializeMetalTargetInfo()

    mi, mi_meta = GPUCompiler.emit_julia(job)
    ir, ir_meta = GPUCompiler.emit_llvm(job, mi)
    obj, asm_meta = GPUCompiler.emit_asm(job, ir; format=LLVM.API.LLVMObjectFile)

    open(metallib_path, "w") do io
        write(io, obj)
    end
    
    return (metallib_path, LLVM.name(ir_meta.entry))
end

function (kernel::MtlKernel)(args...; kwargs...)
    call(kernel, map(mtlconvert, args)...; kwargs...)
end



#launchKernel

##########################################
# Blocking call to a kernel
# Should implement somethjing better
mtlcall(f::MtlFunction, types::Tuple, args...; kwargs...) =
    mtlcall(f, Base.to_tuple_type(types), args...; kwargs...)

function mtlcall(f::MtlFunction, types::Type, args...; kwargs...)
    # Handle kwargs here??
    queue = global_queue(f.lib.device)

    cmd = MTL.commit!(queue) do cmdbuf
        MtlComputeCommandEncoder(cmdbuf) do cce
            enqueue_function(f, args...; cce)
        end
    end
    wait(cmd)
end

##############################################
# Enqueue a function for execution
#
function enqueue_function(f::MtlFunction, args...;
                blocks::MtlDim=1, threads::MtlDim=1,
                cce::MtlComputeCommandEncoder)
    blocks = MtlDim3(blocks)
    threads = MtlDim3(threads)
    (blocks.width>0 && blocks.height>0 && blocks.depth>0)    || throw(ArgumentError("Grid dimensions should be non-null"))
    (threads.width>0 && threads.height>0 && threads.depth>0) || throw(ArgumentError("Thread dimensions should be non-null"))
    # all(threads .< f.maxTotalThreadsPerThreadgroup) || throw(ArgumentError("Max Thread dimension is $(f.maxTotalThreadsPerThreadgroup)"))

    pipeline_state = MtlComputePipelineState(f.lib.device, f)
    # Set the function that we are currently encoding
    MTL.set_function!(cce, pipeline_state)
    # Encode all arguments
    encode_arguments!(cce, f, args...)
    # Flush everything
    MTL.append_current_function!(cce, blocks, threads)
    return nothing
end

#####
function encode_arguments!(cce::MtlComputeCommandEncoder, f::MtlFunction, args...)
    for (i, a) in enumerate(args)
        encode_argument!(cce, f, i, a)
    end
end

function encode_argument!(cce::MtlComputeCommandEncoder, f::MtlFunction, idx::Integer, arg::Nothing)
    @assert idx > 0
    #@check api.clSetKernelArg(k.id, cl_uint(idx-1), sizeof(CL_mem), C_NULL)
    set_bytes!(cce, sizeof(C_NULL), C_NULL, idx)
    return cce
end

function encode_argument!(cce::MtlComputeCommandEncoder, f::MtlFunction, idx::Integer, arg::MtlBuffer)
    @assert idx > 0
    set_buffer!(cce, arg, 0, idx)
    return cce
end

function encode_argument!(cce::MtlComputeCommandEncoder, f::MtlFunction, idx::Integer, arg::Core.LLVMPtr)
    @assert idx > 0

    set_buffer!(cce, MtlBuffer{Float32}(Base.bitcast(MTL.MTLBuffer, arg)), 0, idx)
    return cce
end

function encode_argument!(enc::MTL.MtlComputeCommandEncoder, f::MtlFunction, idx::Integer, val::T) where T
    @assert idx > 0 "Kernel idx must be bigger 0"
    #if does not contain a buffer we can use setbytes
    if !contains_mtlbuffer(T)
        ref, tsize = to_mtl_ref(val)
        set_bytes!(cce, ref, tsize, idx)
    else
        #otherwise, we need an argument buffer
        throw("Not implemented: If an argument contains a mtlbuffer automatic argument encoding is not yet supported.")

        # create an encoder to write into the argument buffer
        argbuf_enc = MtlArgumentEncoder(f, idx)
        # allocate the argument buffer
        argbuf = alloc(Cchar, device(enc), sizeof(argbuf_enc), storage=Shared)
        # assign the argument buffer to the encoder
        MTL.assign_argument_buffer!(argbuf_enc, argbuf, 1)

        # TODO Implement automatic conversion of struct into a assign_argument_buffer

        #for field in val 
        #    MTL.set_field!(argbuf_enc, size(val), 1)
        #    set_buffer!(argbuf_enc, pointer(val), 0, 2)
        #end

        # set argubuf_enc into cce        
    end
    return cce
end

# Encode MtlDeviceArrays as argument buffer?
function encode_argument!(cce::MTL.MtlComputeCommandEncoder, f::MtlFunction, idx::Integer, val::MtlDeviceArray)
    #@assert contains_mtlbuffer(typeof(val))


    # create an encoder to write into the argument buffer
    argbuf_enc = MtlArgumentEncoder(f, idx)
    # allocate the argument buffer
    argbuf = alloc(Cchar, device(cce), sizeof(argbuf_enc), storage=Shared)
    # assign the argument buffer to the arg buff encoder
    MTL.assign_argument_buffer!(argbuf_enc, argbuf, 1)
    # Encode the size of the MtlDeviceArray
    MTL.set_field!(argbuf_enc, size(val), 1)

    # Convert LLVMPtr to MtlBuffer
    #mtl_buf = pointer_buf(val)
    mtl_buf = MtlBuffer{Float32}(Base.bitcast(MTL.MTLBuffer, val.ptr))
    # encode the buffer into the argument buffer
    MTL.set_buffer!(argbuf_enc, mtl_buf, 0, 2)

    MTL.use!(cce, mtl_buf, MTL.ReadWriteUsage) # try using the command_encoder version (no MTL.)

    
    set_buffer!(cce, argbuf, 0, idx)
    @info "Leaked temporary argument buffer $(argbuf.handle) for argument #$idx"
    #TODO memmgmt
    # Why return argbuf??
    # return argbuf
    return cce
end
