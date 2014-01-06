
const _gi_modules = Dict{Symbol,Module}()
const _gi_modsyms = Dict{(Symbol,Symbol),Any}()

function create_module(modname,consts)
    constdecs = [:(const $name = $(Meta.quot(val))) for (name,val) in consts]
    eval(Expr(:toplevel, :(module ($modname) 
        $(Expr(:block, constdecs...))
    end), modname))
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
    #modname = symbol("_$name")
    mod = create_module(name,consts)
    _gi_modules[name] = mod
    mod
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

j_type(t) = t
j_type{T<:Integer}(::Type{T}) = Integer
function create_method(info::GIFunctionInfo)
    ns = get_namespace(info)
    NS = _ns(ns)
    name = get_name(info)
    flags = get_flags(info)
    args = get_args(info)
    argtypes = Type[extract_type(a) for a in args]
    argnames = [symbol("_$(get_name(a))") for a in args]
    if flags & IS_METHOD != 0
        object = get_container(info)
        iface = extract_type(object,true)
        unshift!(argtypes, iface)
        unshift!(argnames, :__instance)
    end
    if flags & IS_CONSTRUCTOR != 0
        if name == :new
            name = symbol("$(get_name(get_container(info)))_new")
        end
    end
    rettype = extract_type(get_return_type(info),true)
    cargtypes = Expr(:tuple, Any[c_type(a) for a in argtypes]...)
    crettype = c_type(rettype)
    symb = get_symbol(info)
    j_call = Expr(:call, name, [ :($(argnames[i])::$(j_type(argtypes[i]))) for i=1:length(argtypes) ]... )
    c_call = :(ccall($(string(symb)), $(c_type(rettype)), $cargtypes))
    append!(c_call.args, argnames)
    if rettype == None
        #pass
    elseif rettype <: GObjectI 
        c_call = :( convert($rettype,$c_call) )
    elseif rettype <: ByteString
        c_call = :( bytestring($c_call) )
    end
    eval(NS, Expr(:function, j_call, quote $c_call end))
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


