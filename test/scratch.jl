#scratch file for interactive testing
#reload("GI.jl")
#module Test
#using GI
#@gimport Clutter init, Actor
#end
cl = GI.GINamespace(:Clutter)
Cl = GI._ns(:Clutter)
act = cl[:Actor]

g = GI.GINamespace(:Gtk)
Clutter = GI._ns(:Clutter)
G = GI._ns(:Gtk)

if false
for f = GI.get_all(ns,GI.GIFunctionInfo)
    wierd = false # whatever we happen to unsupport
    for arg in GI.get_args(f)
        if GI.get_direction(arg) != GI.GI_DIRECTION_IN 
            wierd = true; break
        end
    end
    if wierd
        #print(f)
    end
end
end

