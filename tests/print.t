import "compiler.liszt"
local LMesh = L.require "domains.lmesh"

local mesh = LMesh.Load("examples/mesh.lmesh")

local v = L.NewVector(L.float, {1, 2, 3}) 

local print_stuff = liszt kernel(f : mesh.faces)
    L.print(true)
    L.print(4)
    L.print(2.2)
    L.print()
    L.print(1,2,3,4,5,false,{3.3,3.3})
    var x = 2 + 3
    L.print(x)
    L.print(v)
    L.print(L.id(f))
end

print_stuff(mesh.faces)
