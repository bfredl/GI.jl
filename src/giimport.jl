
const _gi_modules = Dict{Symbol,Module}()
const _gi_modsyms = Dict{(Symbol,Symbol),Any}()
peval(ex) = (print(ex); eval(ex))
function create_module(modname,decs,consts)
    constdecs = [:(const $name = $(Meta.quot(val))) for (name,val) in consts]
    mod =  :(module ($modname); end)
    append!(mod.args[3].args,decs)
    append!(mod.args[3].args,constdecs)
    eval(Expr(:toplevel, mod, modname))
end

function init_ns(name::Symbol)
    if haskey(_gi_modules,name)
        return
    end
    gns = GINamespace(name)
    for path=get_shlibs(gns) 
        dlopen(path,RTLD_GLOBAL) 
    end
    consts = get_consts(gns)
    consts[:GI] = GI
    consts[:__ns] = gns
    enums = get_all(gns, GIEnumOrFlags)
    decs = [enum_decl(enum) for enum in enums]
    #modname = symbol("_$name")
    mod = create_module(name,decs,consts)
    _gi_modules[name] = mod
    mod
end

function enum_decl(enum)
    name = get_name(enum)
    vals = get_enum_values(enum)
    constdecs = [:(const $(uppercase(name)) = $val) for (name,val) in vals]
    :(baremodule ($name) 
        $(Expr(:block, constdecs...))
    end)
end



init_ns(:GObject)
_ns(name) = (init_ns(name); _gi_modules[name])

ensure_name(mod::Module, name) = ensure_name(mod.__ns, name)
function ensure_name(ns::GINamespace, name::Symbol)
    if haskey(_gi_modsyms,(ns.name, name))
        return  _gi_modsyms[(ns.name, name)]
    end
    sym = load_name(ns,name,ns[name])
    _gi_modsyms[(ns.name,name)] = sym
    sym
end

function load_name(ns,name,info::GIObjectInfo)
    rt = extract_type(info,false)
    if find_method(ns[name], :new) != nothing
        #extract_type might not do this, as there will be mutual dependency
        ensure_method(ns,name,:new) 
    end
    rt
end

function load_name(ns,name,info::GIFunctionInfo)
    create_method(info)
end

peval(mod, expr) = (print(expr,'\n'); eval(mod,expr))

function extract_type(info::GIObjectInfo,iface=false) 
    g_type = get_g_type(info)
    name = GLib.g_type_name(g_type)
    iface ? GLib.get_iface(name,g_type) : GLib.get_wrapper(name,g_type)
end


const _gi_methods = Dict{(Symbol,Symbol,Symbol),Any}()
ensure_method(mod::Module, rtype, method) = ensure_method(mod.__ns,rtype,method)
ensure_method(name::Symbol, rtype, method) = ensure_method(_ns(name),rtype,method)

function ensure_method(ns::GINamespace, rtype::Symbol, method::Symbol)
    qname = (ns.name,rtype,method)
    if haskey( _gi_methods, qname)
        return _gi_methods[qname]
    end
    info = ns[rtype][method]
    meth = create_method(info)
    _gi_methods[qname] = meth
    return meth
end
    
c_type(t) = t
c_type{T<:GObjectI}(t::Type{T}) = Ptr{GObjectI}
c_type{T<:ByteString}(t::Type{T}) = Ptr{Uint8}
c_type(t::Type{None}) = Void

j_type(t) = t
j_type{T<:Integer}(::Type{T}) = Integer

immutable Arg
    name::Symbol
    typ::Type
    #ows_refcount::Bool
end
types(args::Array{Arg}) = [a.typ for a in args]
names(args::Array{Arg}) = [a.name for a in args]
jparams(args::Array{Arg}) = [:($(a.name)::$(a.typ)) for a in args]
#there's probably a better way
function make_ccall(id, rtype, args) 
    argtypes = Expr(:tuple, types(args)...)
    c_call = :(ccall($id, $rtype, $argtypes))
    append!(c_call.args, names(args))
    c_call
end

# rconvert could take some flag for refcounting/gc, maybe
rconvert(t::Type,val) = convert(t,val)
rconvert(::Type{ByteString}, val) = bytestring(val) 
# this should not catch void* pointers
rconvert(::Type{Void}, val) = error("something went wrong")

# with some partial-evaluation half-magic
# (or maybe just jit-compile-time macros) 
# this could be simplified significantly
function create_method(info::GIFunctionInfo)
    NS = _ns(get_namespace(info))
    name = get_name(info)
    flags = get_flags(info)
    args = get_args(info)
    prelude = Any[]
    epilogue = Any[]
    retvals = Arg[]
    cargs = Arg[]
    jargs = Arg[]
    if flags & IS_METHOD != 0
        object = get_container(info)
        iface = extract_type(object,true)
        push!(jargs, Arg(:instance, iface))
        push!(cargs, Arg(:instance, c_type(iface)))
    end
    if flags & IS_CONSTRUCTOR != 0 && name == :new
        name = symbol("$(get_name(get_container(info)))_new")
    end
    rettype = extract_type(get_return_type(info),true)
    if rettype != None
        push!(retvals,Arg(:ret, rettype))
    end
    for arg in get_args(info)
        aname = symbol("_$(get_name(arg))")
        typ = extract_type(arg,true)
        dir = get_direction(arg)
        if dir == GI_DIRECTION_IN
            push!(jargs, Arg(aname, j_type(typ)))
            push!(cargs, Arg(aname, c_type(typ)))
        else
            ctyp = c_type(typ)
            wname = symbol("m_$(get_name(arg))")
            push!(prelude, :( $wname = GI.mutable($ctyp) ))
            if dir == GI_DIRECTION_INOUT
                push!(jargs, Arg( aname, j_type(typ)))
                push!(prelude, :( $wname[] = $aname ))
            end
            push!(cargs, Arg(wname, Ptr{ctyp}))
            push!(epilogue,:( $aname = $wname[] ))
            push!(retvals, Arg( aname, typ))
        end
    end

    symb = get_symbol(info)
    j_call = Expr(:call, name, jparams(jargs)... )
    c_call = :( ret = $(make_ccall(string(symb), c_type(rettype), cargs)))
    for ret in retvals
        rname,typ = ret.name, ret.typ
        typ == None && error("something went wrong!")
        # unneccesary if, but makes generated wrappers easier to inspect
        if typ != c_type(typ)
            push!(epilogue,:( $rname = GI.rconvert($typ,$rname) ))
        end
    end
    if length(retvals) > 1
        retstmt = Expr(:tuple, names(retvals)...)
    elseif length(retvals) ==1 
        retstmt = retvals[].name
    else
        retstmt = nothing
    end
    blk = Expr(:block)
    blk.args = [ prelude, c_call, epilogue, retstmt ]
    peval(NS, Expr(:function, j_call, blk))
    return eval(NS, name)
end
    



#some convenience macros, just for the show
macro gimport(ns, names)
    _name = (ns == :Gtk) ? :_Gtk : ns
    NS = _ns(ns)
    ns = GINamespace(ns)
    q = quote  $(esc(_name)) = $(NS) end
    if isa(names,Expr)  && names.head == :tuple
        names = names.args
    else 
        names = [names]
    end
    for item in names
        if isa(item,Symbol)
            name = item; meths = []
        else 
            name = item.args[1]
            meths = item.args[2:end]
        end
        info = NS.__ns[name]
        push!(q.args, :(const $(esc(name)) = $(ensure_name(NS, name))))
        for meth in meths
            push!(q.args, :(const $(esc(meth)) = $(GI.ensure_method(NS, name, meth))))
        end
        if isa(ns[name], GIObjectInfo) && find_method(ns[name], :new) != nothing
            push!(q.args, :(const $(esc(symbol("$(name)_new"))) = $(GI.ensure_method(NS, name, :new))))
        end
    end
    #print(q)
    q
end


