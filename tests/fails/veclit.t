import "compiler.liszt"
local LMesh = L.require "domains.lmesh"
local mesh = LMesh.Load("examples/mesh.lmesh")

local vk = liszt_kernel(v : mesh.vertices)
    var v = { }
end
vk(mesh.vertices)
