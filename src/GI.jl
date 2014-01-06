module GI
    using GLib
    using GLib.MutableTypes
    import Base: convert, cconvert, show, showcompact, length, getindex, setindex!, uppercase
    import GLib: libgobject, libglib, bytestring

    uppercase(s::Symbol) = symbol(uppercase(string(s)))
    # gimport interface (not final in any way)
    export @gimport

    export extract_type, ensure_name, ensure_method

    include(joinpath("..","deps","ext.jl"))
    include("girepo.jl")
    include("giimport.jl")
end
