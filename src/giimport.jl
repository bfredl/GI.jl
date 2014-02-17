#TODO: completely separate code-generation and dyn-importing/caching mechanism
#      make generated code export-clean (no `:($(TypeName))` )
const _gi_modules = Dict{Symbol,Module}()

#we will get rid of this one:
const _gi_modsyms = Dict{(Symbol,Symbol),Any}()

peval(ex) = (print(ex); eval(ex))
function create_module(modname,decs)
    mod =  :(module ($modname); end)
    append!(mod.args[3].args,decs)
    eval(Expr(:toplevel, mod, modname))
end

function get_ns(name::Symbol)
    if haskey(_gi_modules,name)
        return _gi_modules[name]
    end
    gns = GINamespace(name)
    for path=get_shlibs(gns) 
        dlopen(path,RTLD_GLOBAL) 
    end
    decs = Expr[ Expr(:using, :., :., :GI, :_AllTypes), Expr(:using, :Gtk, :GLib) ]
    append!(decs, const_decls(gns))
    (enumdecs, aliases) = enum_decls(gns)
    for d in enumdecs
        eval(_AllTypes, d)
    end
    append!(decs, aliases)
    push!(decs, :( const GI = $GI; const __ns = $gns ) )
    objs = get_all(gns, GIObjectInfo)
    for obj in objs
        if is_gobject(obj)
            ensure_type(obj)
        end
    end

    mod = create_module(name,decs)
    _gi_modules[name] = mod
    mod
end

function enum_decl(enum,enumname)
    vals = get_enum_values(enum)
    body = Expr(:block)
    for (name,val) in vals
        if match(r"^[a-zA-Z_]",string(name)) === nothing
            name = symbol("_$name")
        end
        push!(body.args, :(const $(uppercase(name)) = $val) )
    end
    Expr(:toplevel,Expr(:module, false, symbol(enumname), body))
end

const_decls(ns) = const_decls(ns,x->x)
function const_decls(ns,fmt)
    consts = get_consts(ns)
    decs = Expr[]
    for (name,val) in consts
        name = fmt(name)
        if name !== nothing
            push!(decs, :(const $(symbol(name)) = $(val)) )
        end
    end
    decs
end

function enum_decls(ns)
    enums = get_all(ns, GIEnumOrFlags)
    typedefs = Expr[]
    aliases = Expr[]
    for enum in enums 
        name = get_name(enum)
        longname = enum_name(enum)
        push!(typedefs,enum_decl(enum,longname))
        push!(aliases, :( const $name = _AllTypes.$longname))
    end
    (typedefs,aliases)
end
enum_name(enum) = symbol(string(get_namespace(enum),get_name(enum)))


ensure_name(ns::GINamespace, name) = ensure_name(get_ns(ns.name), name)
function ensure_name(mod::Module, name::Symbol)
    ns = mod.__ns
    if haskey(_gi_modsyms,(ns.name, name))
        return  _gi_modsyms[(ns.name, name)]
    end
    sym = load_name(mod,ns,name,ns[name])
    _gi_modsyms[(ns.name,name)] = sym
    sym
end


#rename me: I am the general context of all dynamically generated code
module _AllTypes
    import GI
    import Gtk
    using Gtk.GLib

    function enum_get(enum, sym::Symbol) 
        enum.(sym)
    end
    enum_get(enum, int::Integer) = int
    export enum_get
    # temporary solution, the @type_decl should go right into the generated module
    # and then aliased in here
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
        eval(Expr(:toplevel, Expr(:export, name, symbol(string(name,"I")))))
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
    fun = create_method(info)
    eval(mod,fun)
end

peval(mod, expr) = (print(expr,'\n'); eval(mod,expr))


const _gi_methods = Dict{(Symbol,Symbol,Symbol),Any}()
ensure_method(mod::Module, rtype, method) = ensure_method(mod.__ns,rtype,method)
ensure_method(name::Symbol, rtype, method) = ensure_method(_ns(name),rtype,method)

function ensure_method(ns::GINamespace, rtype::Symbol, method::Symbol)
    qname = (ns.name,rtype,method)
    if haskey( _gi_methods, qname)
        return _gi_methods[qname]
    end
    info = ns[rtype][method]
    expr = create_method(info)
    meth =  eval(_AllTypes,expr)
    _gi_methods[qname] = meth
    return meth
end

abstract InstanceType
is_pointer(::Type{InstanceType}) = true
typealias TypeInfo Union(GITypeInfo,Type{InstanceType})
    
immutable TypeDesc{T}
    gitype::T
    jtype
    ctype
end

extract_type(info::GIArgInfo) = extract_type(get_type(info))
function extract_type(info::GITypeInfo) 
    base_type = get_base_type(info)
    extract_type(info,base_type)
end

function extract_type(info::GITypeInfo, basetype::Type) 
    typ = symbol(string(basetype))
    if is_pointer(info)
        typ = :(Ptr{$typ})
    end
    TypeDesc(basetype,:Any,typ)
end

#  T<:SomeType likes to steal this:
extract_type(info::GITypeInfo, basetype::Type{None}) = TypeDesc(None, :Any, :None)

function extract_type(info::GITypeInfo, basetype::Type{ByteString})
    @assert is_pointer(info)
    TypeDesc{Type{ByteString}}(ByteString,:Any,:(Ptr{Uint8}))
end
function convert_from_c(name::Symbol, arginfo::ArgInfo, typeinfo::TypeDesc{Type{ByteString}}) 
    owns = get_ownership_transfer(arginfo) != TRANSFER_NOTHING
    expr = :( ($name == C_NULL) ? nothing : GLib.bytestring($name, $owns))
end
        
abstract GStruct #placeholder
function extract_type(typeinfo::TypeInfo, info::GIStructInfo) 
    #FIXME: not neccesarily pointer!
    TypeDesc(info,:Any,:(Ptr{Void}))
end

extract_type(typeinfo::GITypeInfo,info::GIEnumOrFlags) = TypeDesc(info,:Any, :Enum)
function convert_to_c{T<:GIEnumOrFlags}(argname::Symbol, info::GIArgInfo, ti::TypeDesc{T})
    :( enum_get($(enum_name(ti.gitype)),$argname) ) 
end

function extract_type(typeinfo::GITypeInfo,info::Type{GICArray}) 
    @assert is_pointer(typeinfo)
    #elm = get_param_type(typeinfo,0)
    #TODO: something more intresting
    TypeDesc(typeinfo,:Any, :(Ptr{Void}))
end

function extract_type{T<:GLib._LList}(typeinfo::GITypeInfo,listtype::Type{T}) 
    @assert is_pointer(typeinfo)
    elm = get_param_type(typeinfo,0)
    elmtype = extract_type(elm).ctype
    lt = listtype == GLib._GSList ? :(GLib._GSList) : :(GLib._GList) 
    TypeDesc{Type{GList}}(GList, :(GLib.LList{$lt{$elmtype}}), :(Ptr{$lt{$elmtype}}))
end
function convert_from_c(name::Symbol, arginfo::ArgInfo, typeinfo::TypeDesc{Type{GList}}) 
    #owns = get_ownership_transfer(arginfo) != TRANSFER_NOTHING
    expr = :( GLib.GList($name) )
end

function extract_type(typeinfo::GITypeInfo,info::GICallbackInfo) 
    TypeDesc(info,:Any, :(Ptr{Void}))
end

typealias ObjectLike Union(GIObjectInfo, GIInterfaceInfo)

function typename(info::GIObjectInfo) 
    gname = ensure_type(info)
    symbol(string(gname,"I"))
end

# not sure the best way to implement this given no multiple inheritance
# maybe clutter_container_add_actor should become container_add_actor
typename(info::GIInterfaceInfo) = :GObjectI #FIXME

function extract_type(typeinfo::TypeInfo, info::ObjectLike)
    # dynamic ? GLib.gtype_ifaces[gname] : symbol(gname)
    if is_pointer(typeinfo)
        TypeDesc(info,typename(info),:(Ptr{GObjectI}))
    else
        # a GList has implicitly pointers to all elements
        TypeDesc(info,:INVALID,:GObjectI)
    end
end

#this should only be used for stuff that's hard to implement as cconvert
function convert_to_c(name::Symbol, info::GIArgInfo, ti::TypeDesc) 
    nothing
end

function convert_from_c{T}(argname::Symbol, arginfo::ArgInfo, ti::TypeDesc{T}) 
    if ti.jtype != :Any
        :(convert($(ti.jtype), $argname))
    else
        nothing
    end
end

immutable Arg
    name::Symbol
    typ
end
types(args::Array{Arg}) = [a.typ for a in args]
names(args::Array{Arg}) = [a.name for a in args]
jparams(args::Array{Arg}) = [a.typ != :Any ? :($(a.name)::$(a.typ)) : a.name for a in args]
#there's probably a better way
function make_ccall(id, rtype, args) 
    argtypes = Expr(:tuple, types(args)...)
    c_call = :(ccall($id, $rtype, $argtypes))
    append!(c_call.args, names(args))
    c_call
end

function err_buf()
    err = GI.mutable(Ptr{GError}); 
    err.x = C_NULL
    err
end
function check_err(err::Mutable{Ptr{GError}})
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
    name = get_name(info)
    flags = get_flags(info)
    args = get_args(info)
    prologue = Any[]
    epilogue = Any[]
    retvals = Symbol[]
    cargs = Arg[]
    jargs = Arg[]
    if flags & IS_METHOD != 0
        object = get_container(info)
        typeinfo = extract_type(InstanceType,object)
        push!(jargs, Arg(:instance, typeinfo.jtype))
        push!(cargs, Arg(:instance, typeinfo.ctype))
    end
    if flags & IS_CONSTRUCTOR != 0
        name = symbol("$(get_name(get_container(info)))_$name")
    end
    rettype = extract_type(get_return_type(info))
    if rettype.ctype != :None
        expr = convert_from_c(:ret,info,rettype)
        if expr != nothing
            push!(epilogue, :(ret = $expr))
        end
        push!(retvals,:ret)
    end
    for arg in get_args(info)
        aname = symbol("_$(get_name(arg))")
        typ = extract_type(arg)
        dir = get_direction(arg)
        if dir != DIRECTION_OUT
            push!(jargs, Arg( aname, typ.jtype))
            expr = convert_to_c(aname,arg,typ)
            if expr != nothing
                push!(prologue, :($aname = $expr))
            end
        end

        if dir == DIRECTION_IN
            push!(cargs, Arg(aname, typ.ctype))
        else
            ctype = typ.ctype
            wname = symbol("m_$(get_name(arg))")
            push!(prologue, :( $wname = GI.mutable($ctype) ))
            if dir == DIRECTION_INOUT
                push!(prologue, :( $wname[] = Base.cconvert($ctype,$aname) ))
            end
            push!(cargs, Arg(wname, :(Ptr{$ctype})))
            push!(epilogue,:( $aname = $wname[] ))
            expr = convert_from_c(aname,arg,typ)
            if expr != nothing
                push!(epilogue, :($aname = $expr))
            end
            push!(retvals, aname)
        end
    end
    if flags & THROWS != 0
        push!(prologue, :( err = GI.err_buf() ))
        push!(cargs, Arg(:err, :(Ptr{Ptr{GError}})))
        unshift!(epilogue, :( GI.check_err(err) ))
    end

    symb = get_symbol(info)
    j_call = Expr(:call, name, jparams(jargs)... )
    c_call = :( ret = $(make_ccall(string(symb), rettype.ctype, cargs)))
    if length(retvals) > 1
        retstmt = Expr(:tuple, retvals...)
    elseif length(retvals) ==1 
        retstmt = retvals[]
    else
        retstmt = :nothing
    end
    blk = Expr(:block)
    blk.args = [ prologue, c_call, epilogue, retstmt ]
    fun = Expr(:function, j_call, blk)
    println(fun)
    fun

end
    
#convenience macro for testing 
#final API might be different
macro gimport(ns, names)
    _name = (ns == :Gtk) ? :_Gtk : ns
    NS = get_ns(ns)
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
    println(q)
    q
end


