using Gtk, Gtk.GLib
using GI

@gimport Gtk RadioButton(get_group), Button(get_label)

group = Gtk.RadioButtonGroup(["elm"])
list = get_group(group.anchor)
@assert isa(list, GLib.GList)
@assert get_label(list[1]) == "elm"

