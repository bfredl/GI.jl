using Gtk
using GI

@gimport GtkClutter init, Embed(get_stage) 
@gimport Clutter Actor(get_flags,set_reactive), Stage(set_color), Text(new_with_text), Container(add_actor)

GtkClutter.init(0,C_NULL)

embed = Embed_new()
stage = get_stage(embed)

#hack until we get proper struct support
color =  Gtk.mutable(Gtk.RGBA(128,128,255,255))
set_color(stage, color)

txt = new_with_text("Sans 20", "Clutter text")
add_actor(stage,txt)

#enums
@assert get_flags(txt) & Clutter.ActorFlags.REACTIVE == 0
set_reactive(txt,true)
@assert get_flags(txt) & Clutter.ActorFlags.REACTIVE != 0


# GI inherits GObject support from Gtk.jl, for instance properties, signals
print(txt)
signal_connect(txt,"button-press-event") do actor,event
    print("clicked\n")
end

vbox = @GtkBox(:v)
push!(vbox,embed)
push!(vbox,@GtkLabel("Gtk text"))
window = @GtkWindow(vbox, "GtkClutter Test", 300, 300)
showall(window)
nothing

