module Test
using GI
GI.@gimport Clutter init, Actor
Clutter.init(0, C_NULL)
actor = Actor_new()
display(actor)
@assert isa(actor,GI.GObject)
@assert isa(actor,Actor)

@assert Clutter.adiaeresis == 228
#might not be consistend across clutter versions: 
@assert Clutter.INPUT_NULL == "null"

@assert Clutter.SwipeDirection.LEFT == 4

end 
