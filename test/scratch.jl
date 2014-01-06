#scratch file for interactive testing
reload("GI.jl")
#module Test
#using GI
#@gimport Clutter init, Actor
#end
ns = GI.GINamespace(:Clutter)
Clutter = GI._ns(:Clutter)
act = ns[:Actor]

ns = GI.GINamespace(:Gtk)
for f = GI.get_all(ns,GI.GIFunctionInfo)
    wierd = false # whatever we happen to unsupport
    for arg in GI.get_args(f)
        if GI.get_direction(arg) != GI.GI_DIRECTION_IN 
            wierd = true; break
        end
    end
    if wierd
        print(f)
    end
end

