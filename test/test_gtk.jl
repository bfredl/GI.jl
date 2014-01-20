using GI

gtk = GI.GINamespace(:Gtk)

window = gtk[:Window]
@assert isa(window, GI.GIObjectInfo)

wnew = GI.find_method(window,:new)
wmove = GI.find_method(window,:move)

args = GI.get_args(wmove)
@assert length(args) == 2

argx = args[1]
@assert GI.get_name(argx) == :x
@assert GI.extract_type(argx) == Int32

GI.ensure_name(gtk, :Window)
GI.ensure_method(gtk, :Window, :move)

@gimport Gtk init, main, Widget(show,get_size_request,set_size_request)
@gimport Gtk Window(move,set_title,get_title)  
init(0,C_NULL)
w = Window_new(0)
show(w) #NB: currently doesn't extend Base.show
move(w,100,100)

#string passing
@assert get_title(w) == nothing # handle NULL returns
set_title(w,"GI test")
@assert get_title(w) == "GI test"

set_size_request(w,300,400)
@assert get_size_request(w) == (300,400)

@assert _Gtk.STOCK_SAVE == "gtk-save" #maybe not version independent?
@assert _Gtk.TreeModelFlags.LIST_ONLY == 2
#main() //TODO: main-loop integration in a generic way 


@gimport GdkPixbuf Pixbuf(new_from_file)
#shall throw
new_from_file("this_file_doesnt_exist")

