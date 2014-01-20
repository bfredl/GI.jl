Julia bindings using libgobject-introspection.

This is still in a very early stage.

What works:
* GObject types, with constructors and methods (including property accessors)
* passing of numeric types, string constants, gobjects
* runtime type-determination of returned GObject pointers
* Full type compatibility with Gtk.jl 
* properties and signal handling (from Gtk.jl)
* constants and enums/flags 
* multiple return values using c-pointers
* Basic error handling

What needs to be done:
* passing of arrays
* memory management still quite rough
* proper support for structs and abstract interfaces
* consistent naming of things
* callback parameters
* much more...
