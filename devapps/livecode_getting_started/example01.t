import "ebb"

local ioOff = require 'ebb.domains.ioOff'
local mesh  = ioOff.LoadTrimesh(
  'devapps/livecode_getting_started/octa.off')

print(mesh.vertices:Size())
print(mesh.triangles:Size())


----------------------------

mesh.vertices.pos:print()
mesh.triangles.v:print()


----------------------------

-- At this point open up the OFF file to show them TADA.

----------------------------

-- Then, let's try translating the mesh vertices

local ebb translate ( v : mesh.vertices )
  v.pos += {1,0,0}
end

mesh.vertices:foreach(translate)

mesh.vertices.pos:print()