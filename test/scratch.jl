#scratch file for interactive testing
reload("../src/GI.jl")
#module Test
#using GI
#@gimport Clutter init, Actor
#end
cl = GI.GINamespace(:Clutter)
#Cl = GI.get_ns(:Clutter)
act = cl[:Actor]

g = GI.GINamespace(:Gtk)
G = GI.get_ns(:Gtk)

i = g[:init]
args = GI.get_args(i)
a = args[2]
GI.create_method(i)

