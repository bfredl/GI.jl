using GI;

GI.write_gtk_consts("_TEST_CONSTS")

module GtkConstants
    map(eval,include(joinpath(pwd(),"_TEST_CONSTS")).args)
end
