scratch file for interactive testing
reload("GI.jl")
#module Test
#using GI
#@gimport Clutter init, Actor
#end
ns = GI.GINamespace(:Clutter)
Clutter = GI._ns(:Clutter)
act = ns[:Actor]

