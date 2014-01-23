const _gi_modules = Dict{Symbol,Module}()

#we will get rid of this one:
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
    objs = get_all(gns, GIObjectInfo)
    for obj in objs
        if is_gobject(obj)
            ensure_type(obj)
        end
    end

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

_ns(name) = (init_ns(name); _gi_modules[name])

ensure_name(ns::GINamespace, name) = ensure_name(_ns(ns.name), name)
function ensure_name(mod::Module, name::Symbol)
    ns = mod.__ns
    if haskey(_gi_modsyms,(ns.name, name))
        return  _gi_modsyms[(ns.name, name)]
    end
    sym = load_name(mod,ns,name,ns[name])
    _gi_modsyms[(ns.name,name)] = sym
    sym
end


module _AllTypes
    import GI
    import Gtk.GLib
    const GObject = GLib.GObject
    # temporary solution, the @type_decl should go right into the generated module
    function ensure_type(info::GI.GIObjectInfo)
        g_type = GI.get_g_type(info)
        name = symbol(GLib.g_type_name(g_type))
        if name == :GObject
            return name
        end
        if(isdefined(_AllTypes, name))
            return name
        end
            
        @eval @GLib.Gtype_decl $name $g_type (
            g_type(::Type{$(esc(name))}) = esc(get_g_type)($info) )
        name
    end
end
# we may use `using Alltypes` to mean "import all gtypenames"
const ensure_type = _AllTypes.ensure_type 
        
function load_name(mod,ns,name::Symbol,info::GIObjectInfo)
    gname = ensure_type(info)
    iname = symbol(string(name,"I"))
    wrap = GLib.gtype_wrappers[gname]
    iface = GLib.gtype_ifaces[gname]
    eval(mod, :(const $name = $wrap))
    eval(mod, :(const $iname = $iface))
    if find_method(ns[name], :new) != nothing
        #ensure_type might not do this, as there will be mutual dependency
        ensure_method(ns,name,:new) 
    end
    wrap
end

function load_name(mod,ns,name::Symbol,info::GIInterfaceInfo)
    GObjectI #FIXME
end

function load_name(mod,ns,name,info::GIFunctionInfo)
    create_method(info)
end

peval(mod, expr) = (print(expr,'\n'); eval(mod,expr))

function extract_type(info::GIObjectInfo,iface=false) 
    gname = ensure_type(info)
    iface ? GLib.gtype_ifaces[gname] : GLib.gtype_wrappers[gname]
end

function extract_type(info::GIInterfaceInfo,iface=false) 
    # not sure the best way to implement this given no multiple inheritance
    # maybe clutter_container_add_actor should become container_add_actor
    GObjectI #FIXME 
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
j_type(::Type{Ptr{GStruct}}) = Mutable #FIXME

immutable Arg
    name::Symbol
    typ::Type
    owns::Bool #true: we should free the string/etc
    maybenull::Bool
    Arg(nam,typ,owns=false,maybe=false) = new(nam,typ,owns,maybe)
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

function check_gerr(err::Mutable{Ptr{GError}})
    if err[] != C_NULL
        gerror = GError(err[])
        emsg = bytestring(gerror.message)
        ccall((:g_clear_error,libglib),Void,(Ptr{Ptr{GError}},),err)
        error(emsg)
    end
end

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
    if flags & IS_CONSTRUCTOR != 0
        name = symbol("$(get_name(get_container(info)))_$name")
    end
    rettype = extract_type(get_return_type(info),true)
    if rettype != None
        owns = get_caller_owns(info) != TRANSFER_NOTHING
        maybe = may_return_null(info)
        if rettype == ByteString
            maybe = true # seems that Girepository lies to us
        end

        push!(retvals,Arg(:ret, rettype, owns, maybe))
    end
    for arg in get_args(info)
        aname = symbol("_$(get_name(arg))")
        typ = extract_type(arg,true)
        dir = get_direction(arg)
        owns = get_ownership_transfer(arg) != TRANSFER_NOTHING
        maybenull = may_be_null(arg)
        if dir == DIRECTION_IN
            push!(jargs, Arg(aname, j_type(typ)))
            push!(cargs, Arg(aname, c_type(typ)))
        else
            ctyp = c_type(typ)
            wname = symbol("m_$(get_name(arg))")
            push!(prelude, :( $wname = GI.mutable($ctyp) ))
            if dir == DIRECTION_INOUT
                push!(jargs, Arg( aname, j_type(typ)))
                push!(prelude, :( $wname[] = Base.cconvert($ctyp,$aname) ))
            end
            push!(cargs, Arg(wname, Ptr{ctyp}))
            push!(epilogue,:( $aname = $wname[] ))
            push!(retvals, Arg( aname, typ, owns, maybenull))
        end
    end
    if flags & THROWS != 0
        push!(prelude, :( err = GI.mutable(Ptr{GI.GError}); err[] = C_NULL; ))
        push!(cargs, Arg(:err, Ptr{Ptr{GI.GError}}))
        unshift!(epilogue, :( GI.check_gerr(err) ))
    end

    symb = get_symbol(info)
    j_call = Expr(:call, name, jparams(jargs)... )
    c_call = :( ret = $(make_ccall(string(symb), c_type(rettype), cargs)))
    for r in retvals
        nam = r.name
        r.typ == None && error("something went wrong!")
        ctype = c_type(r.typ)
        rtype = r.maybenull ? Maybe(r.typ) : r.typ
        # unneccesary if, but makes generated wrappers easier to inspect
        if rtype != ctype
            push!(epilogue,:( $nam = GI.rconvert($rtype,$nam,$(r.owns) )))
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
    
#convenience macro for testing 
#final API might be different
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


