abstract GIRepository
const girepo = ccall((:g_irepository_get_default, libgi), Ptr{GIRepository}, () )

abstract GITypelib

abstract GIBaseInfo
# a GIBaseInfo we own a reference to
type GIInfo{Typeid} 
    handle::Ptr{GIBaseInfo}
end

function GIInfo(h::Ptr{GIBaseInfo},owns=true) 
    if h == C_NULL 
        error("Cannot constrct GIInfo from NULL")
    end
    typeid = int(ccall((:g_base_info_get_type, libgi), Enum, (Ptr{GIBaseInfo},), h))
    info = GIInfo{typeid}(h)
    owns && finalizer(info, info_unref)
    info
end
maybeginfo(h::Ptr{GIBaseInfo}) = (h == C_NULL) ? nothing : GIInfo(h)

# don't call directly, called by gc
function info_unref(info::GIInfo) 
    #core dumps on reload("GTK.jl"), 
    #ccall((:g_base_info_unref, libgi), Void, (Ptr{GIBaseInfo},), info.handle)
    info.handle = C_NULL
end

convert(::Type{Ptr{GIBaseInfo}},w::GIInfo) = w.handle

const GIInfoTypesShortNames = (:Invalid, :Function, :Callback, :Struct, :Boxed, :Enum, :Flags, :Object, :Interface, :Constant, :Unknown, :Union, :Value, :Signal, :VFunc, :Property, :Field, :Arg, :Type, :Unresolved)
const GIInfoTypeNames = [ Base.symbol("GI$(name)Info") for name in GIInfoTypesShortNames]

const GIInfoTypes = Dict{Symbol, Type}()

for (i,itype) in enumerate(GIInfoTypesShortNames)
    let lowername = symbol(lowercase(string(itype)))
        @eval typealias $(GIInfoTypeNames[i]) GIInfo{$(i-1)}
        GIInfoTypes[lowername] = GIInfo{i-1}
    end
end

typealias GICallableInfo Union(GIFunctionInfo,GIVFuncInfo, GICallbackInfo, GISignalInfo)
typealias GIEnumOrFlags Union(GIEnumInfo,GIFlagsInfo)
typealias GIRegisteredTypeInfo Union(GIEnumOrFlags,GIInterfaceInfo, GIObjectInfo, GIStructInfo, GIUnionInfo)

show{Typeid}(io::IO, ::Type{GIInfo{Typeid}}) = print(io, GIInfoTypeNames[Typeid+1])

function show(io::IO, info::GIInfo)
    show(io, typeof(info)) 
    print(io,"(:$(get_namespace(info)), :$(get_name(info)))")
end

show(io::IO, info::GITypeInfo) = print(io,"GITypeInfo($(extract_type(info)))")
show(io::IO, info::GIArgInfo) = print(io,"GIArgInfo(:$(get_name(info)),$(extract_type(info)))")
showcompact(io::IO, info::GIArgInfo) = show(io,info) # bug in show.jl ?

function show(io::IO, info::GIFunctionInfo) 
    print(io, "$(get_namespace(info)).") 
    flags = get_flags(info)
    if flags & (IS_CONSTRUCTOR | IS_METHOD) != 0
        cls = get_container(info)
        print(io, "$(get_name(cls)).")
    end
    print(io,"$(get_name(info))(")
    for arg in get_args(info)
        print(io, "$(get_name(arg))::")
        show(io, get_type(arg))
        dir = get_direction(arg)
        alloc = is_caller_allocates(arg)
        if dir == DIRECTION_OUT
            print(io, " OUT($alloc)")
        elseif dir == DIRECTION_INOUT
            print(io, " INOUT")
        end
        print(io, ", ")
    end
    print(io,")::") 
    show(io, get_return_type(info))
    if flags & THROWS != 0
        print(io, " THROWS")
    end

end


immutable GINamespace
    name::Symbol
    function GINamespace(namespace::Symbol, version=nothing)
        #TODO: stricter version sematics?
        gi_require(namespace, version)
        new(namespace)
    end
end 
convert(::Type{Symbol}, ns::GINamespace) = ns.name
convert(::Type{Ptr{Uint8}}, ns::GINamespace) = convert(Ptr{Uint8}, ns.name)

function gi_require(namespace, version=nothing)
    if version==nothing
        version = C_NULL
    end
    GError() do error_check
        typelib = ccall((:g_irepository_require, libgi), Ptr{GITypelib}, 
            (Ptr{GIRepository}, Ptr{Uint8}, Ptr{Uint8}, Cint, Ptr{Ptr{GError}}), 
            girepo, namespace, version, 0, error_check)
        return  typelib !== C_NULL
    end
end

function gi_find_by_name(namespace, name)
    info = ccall((:g_irepository_find_by_name, libgi), Ptr{GIBaseInfo}, 
           (Ptr{GIRepository}, Ptr{Uint8}, Ptr{Uint8}), girepo, namespace, name)
    if info == C_NULL
        error("Name $name not found in $namespace")
    end
    GIInfo(info) 
end

#GIInfo(namespace, name::Symbol) = gi_find_by_name(namespace, name)

#TODO: make ns behave more like Array and/or Dict{Symbol,GIInfo}?
length(ns::GINamespace) = int(ccall((:g_irepository_get_n_infos, libgi), Cint, (Ptr{GIRepository}, Ptr{Uint8}), girepo, ns))
function getindex(ns::GINamespace, i::Integer) 
    GIInfo(ccall((:g_irepository_get_info, libgi), Ptr{GIBaseInfo}, (Ptr{GIRepository}, Ptr{Uint8}, Cint), girepo, ns, i-1 ))
end
getindex(ns::GINamespace, name::Symbol) = gi_find_by_name(ns, name)

function get_all{T<:GIInfo}(ns::GINamespace, t::Type{T})
    all = GIInfo[]
    for i=1:length(ns)
        info = ns[i]
        if isa(info,t)
            push!(all,info)
        end
    end
    all
end


function get_shlibs(ns)
    names = ccall((:g_irepository_get_shared_library, libgi), Ptr{Uint8}, (Ptr{GIRepository}, Ptr{Uint8}), girepo, ns)
    if names != C_NULL
        split(bytestring(names),",")
    else
        String[]
    end
end
get_shlibs(info::GIInfo) = get_shlibs(get_namespace(info))

function find_by_gtype(gtypeid::Csize_t)
    GIInfo(ccall((:g_irepository_find_by_gtype, libgi), Ptr{GIBaseInfo}, (Ptr{GIRepository}, Csize_t), girepo, gtypeid))
end

GIInfoTypes[:method] = GIFunctionInfo
GIInfoTypes[:callable] = GICallableInfo
GIInfoTypes[:registered_type] = GIRegisteredTypeInfo
GIInfoTypes[:base] = GIInfo
GIInfoTypes[:enum] = GIEnumOrFlags

Maybe(T) = Union(T,Nothing)

rconvert(t,v) = rconvert(t,v,false)
rconvert(t::Type,val,owns) = convert(t,val)
rconvert(::Type{ByteString}, val,owns) = bytestring(val,owns) 
rconvert(::Type{Symbol}, val,owns) = symbol(bytestring(val,owns) )
rconvert(::Type{GIInfo}, val::Ptr{GIBaseInfo},owns) = GIInfo(val,owns) 
#rconvert{T}(::Type{Union(T,Nothing)}, val,owns) = (val == C_NULL) ? nothing : rconvert(T,val,owns)
# :(
for typ in [GIInfo, ByteString, GObject]
    @eval rconvert(::Type{Union($typ,Nothing)}, val,owns) = (val == C_NULL) ? nothing : rconvert($typ,val,owns)
end
rconvert(::Type{Void}, val) = error("something went wrong")

# one-> many relationships
for (owner, property) in [
    (:object, :method), (:object, :signal), (:object, :interface),
    (:object, :property), (:object, :constant), (:object, :field),
    (:interface, :method), (:interface, :signal), (:callable, :arg),
    (:enum, :value)]
    @eval function $(symbol("get_$(property)s"))(info::$(GIInfoTypes[owner]))
        n = int(ccall(($("g_$(owner)_info_get_n_$(property)s"), libgi), Cint, (Ptr{GIBaseInfo},), info))
        GIInfo[ GIInfo( ccall(($("g_$(owner)_info_get_$property"), libgi), Ptr{GIBaseInfo}, (Ptr{GIBaseInfo}, Cint), info, i)) for i=0:n-1]
    end
    if property == :method
        @eval function $(symbol("find_$(property)"))(info::$(GIInfoTypes[owner]), name)
            ptr = ccall(($("g_$(owner)_info_find_$(property)"), libgi), Ptr{GIBaseInfo}, (Ptr{GIBaseInfo},Ptr{Uint8}), info, name)
            rconvert(Maybe(GIInfo), ptr, true)
        end
    end
end
getindex(info::GIRegisteredTypeInfo, name::Symbol) = find_method(info, name)

typealias MaybeGIInfo Union(GIInfo,Nothing)
# one->one
# FIXME: memory management of GIInfo:s
ctypes = [GIInfo=>Ptr{GIBaseInfo},
         MaybeGIInfo=>Ptr{GIBaseInfo},
          Symbol=>Ptr{Uint8}]
for (owner,property,typ) in [
    (:base, :name, Symbol), (:base, :namespace, Symbol),
    (:base, :container, MaybeGIInfo), (:registered_type, :g_type, GType), (:object, :parent, MaybeGIInfo),
    (:callable, :return_type, GIInfo), (:callable, :caller_owns, Enum),
    (:function, :flags, Enum), (:function, :symbol, Symbol),
    (:arg, :type, GIInfo), (:arg, :direction, Enum), (:arg, :ownership_transfer, Enum),
    (:type, :tag, Enum), (:type, :interface, GIInfo), (:type, :array_type, Enum), 
    (:type, :array_length, Cint), (:type, :array_fixed_size, Cint), (:constant, :type, GIInfo), 
    (:value, :value, Int64) ]

    ctype = get(ctypes, typ, typ)
    @eval function $(symbol("get_$(property)"))(info::$(GIInfoTypes[owner]))
        rconvert($typ,ccall(($("g_$(owner)_info_get_$(property)"), libgi), $ctype, (Ptr{GIBaseInfo},), info))
    end
end

get_name(info::GITypeInfo) = symbol("<gtype>")
get_name(info::GIInvalidInfo) = symbol("<INVALID>")

get_param_type(info::GITypeInfo,n) = rconvert(MaybeGIInfo, ccall(("g_type_info_get_param_type", libgi), Ptr{GIBaseInfo}, (Ptr{GIBaseInfo}, Cint), info, n))

qual_name(info::GIRegisteredTypeInfo) = (get_namespace(info),get_name(info))

for (owner,flag) in [ (:type, :is_pointer), (:callable, :may_return_null), (:arg, :is_caller_allocates), (:arg, :may_be_null), (:type, :is_zero_terminated) ]
    @eval function $flag(info::$(GIInfoTypes[owner]))
        ret = ccall(($("g_$(owner)_info_$(flag)"), libgi), Cint, (Ptr{GIBaseInfo},), info)
        return ret != 0
    end
end

is_gobject(::Nothing) = false
function is_gobject(info::GIObjectInfo)
    if GLib.g_type_name(get_g_type(info)) == :GObject
        true
    else 
        is_gobject(get_parent(info))
    end
end


const typetag_primitive = [
    Void,Bool,Int8,Uint8,
    Int16,Uint16,Int32,Uint32,
    Int64,Uint64,Cfloat,Cdouble,
    GType, 
    ByteString
    ]
const TAG_BASIC_MAX = 13
const TAG_ARRAY = 15
const TAG_INTERFACE = 16 
const TAG_GLIST = 17 
const TAG_GSLIST = 18 


abstract GIArrayType{kind}
const GI_ARRAY_TYPE_C = 0
const GI_ARRAY_TYPE_ARRAY = 1
const GI_ARRAY_TYPE_PTR_ARRAY = 2
const GI_ARRAY_TYPE_BYTE_ARRAY =3

get_base_type(info::GIConstantInfo) = get_base_type(get_type(info))
function get_base_type(info::GITypeInfo) 
    tag = get_tag(info)
    if tag <= TAG_BASIC_MAX
        typetag_primitive[tag+1]
    elseif tag == TAG_INTERFACE
        # Object Types n such
        get_interface(info)
    elseif tag == TAG_ARRAY
        GIArrayType{int(get_array_type(info))}
    elseif tag == TAG_GLIST
        GLib._GSList
    elseif tag == TAG_GSLIST
        GLib._GList
    else
        print(tag)
        return Nothing
    end
end

function show(io::IO,info::GITypeInfo) 
    bt = get_base_type(info)
    if is_pointer(info)
        print(io,"Ptr{")
    end
    if isa(bt,Type) && bt <: GIArrayType && bt != None
        zero = is_zero_terminated(info)
        print(io,"$bt($zero,")
        fs = get_array_fixed_size(info)
        len = get_array_length(info)
        if fs >= 0 
            show(io, fs)
        elseif len >= 0
            call = get_container(get_container(info))
            arg = get_args(call)[len+1]
            show(io, get_name(arg))
        end
        print(io,", ")
        param = get_param_type(info,0)
        show(io,param)
        print(io,")")
    elseif isa(bt,Type) && bt <: GLib._LList && bt != None
        print(io,"$bt{")
        param = get_param_type(info,0)
        show(io,param)
        print(io,"}")
    else
        print(io,bt)
    end
    if is_pointer(info)
        print(io,"}")
    end
end

function get_value(info::GIConstantInfo)
    typ = get_base_type(info)
    x = Array(Int64,1) #or mutable
    size = ccall((:g_constant_info_get_value,libgi),Cint,(Ptr{GIBaseInfo}, Ptr{Void}), info, x) 
    if typ <: Number
        unsafe_load(cconvert(Ptr{typ}, x))
    elseif typ == ByteString
        strptr = unsafe_load(convert(Ptr{Ptr{Uint8}},x))
        val = bytestring(strptr)
        ccall((:g_constant_info_free_value,libgi), Void, (Ptr{GIBaseInfo}, Ptr{Void}), info, x)
        val
    else
        nothing#unimplemented
    end
end

function get_consts(gns)
    consts = (Symbol,Any)[]
    for c in get_all(gns,GIConstantInfo)
        name = get_name(c)
        if !ismatch(r"^[a-zA-Z_]",string(name))
            name = symbol("_$name") #FIXME: might collide
        end
        val = get_value(c)
        if val != nothing
            push!(consts, (name,val))
        end
    end
    consts
end

function get_enums(gns)
    enums = get_all(gns, GIEnumOrFlags)
    [(get_name(enum),get_enum_values(enum),isa(enum,GIFlagsInfo)) for enum in enums]
end

function get_enum_values(info::GIEnumOrFlags)
    valinfos = get_values(info)
    [(get_name(i),get_value(i)) for i in get_values(info)]
end

const IS_METHOD     = 1 << 0
const IS_CONSTRUCTOR = 1 << 1
const IS_GETTER      = 1 << 2
const IS_SETTER      = 1 << 3
const WRAPS_VFUNC    = 1 << 4
const THROWS = 1 << 5

const DIRECTION_IN = 0
const DIRECTION_OUT =1 
const DIRECTION_INOUT =2

const TRANSFER_NOTHING =0
const TRANSFER_CONTAINER =1
const TRANSFER_EVERYTHING =2
