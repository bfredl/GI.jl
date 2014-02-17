using GI
using Gtk.GLib
ns = GI.GINamespace(:Gtk)
fs = GI.get_all(ns,GI.GIFunctionInfo)
objs = GI.get_all(ns,GI.GIObjectInfo)
for o in objs
    append!(fs,GI.get_methods(o))
end

for f in fs 
    lustig = false # whatever we happen to unsupport
    for arg in [GI.get_args(f), f] # f is return value
        bt = GI.get_base_type(GI.get_type(arg))
        if isa(bt,Type) && bt <: Union(GLib._LList) && bt != None
            lustig = true; break
        end
    end
    if lustig
        println(f)
        GI.create_method(f)
    end
end
