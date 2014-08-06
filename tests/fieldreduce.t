import "compiler.liszt"

local LMesh = L.require "domains.lmesh"
local M = LMesh.Load("examples/mesh.lmesh")

local V = M.vertices
local P = V.position

local loc_data = {}
function init_loc_data (loc_data)
	P:MoveTo(L.CPU)
	local Pdata = P:DataPtr()
	for i = 0, V:Size() - 1 do
		loc_data[i] = {Pdata[i].d[0], Pdata[i].d[1], Pdata[i].d[2]}
	end
	P:MoveTo(L.default_processor)
end
init_loc_data(loc_data)

function shift(x,y,z)
	local shift_kernel = liszt kernel(v : M.vertices)
	    v.position += {x,y,z}
	end
	shift_kernel(M.vertices)

	P:MoveTo(L.CPU)
	local Pdata = P:DataPtr()
	for i = 0, V:Size() - 1 do

		local v = Pdata[i]
		local d = loc_data[i]

		d[1] = d[1] + x
		d[2] = d[2] + y
		d[3] = d[3] + z

		--print("Pos " .. tostring(i) .. ': (' .. tostring(v[0]) .. ', ' .. tostring(v[1]) .. ', ' .. tostring(v[2]) .. ')')
		--print("Loc " .. tostring(i) .. ': (' .. tostring(d[1]) .. ', ' .. tostring(d[2]) .. ', ' .. tostring(d[3]) .. ')')
		assert(v.d[0] == d[1])
		assert(v.d[1] == d[2])
		assert(v.d[2] == d[3])
	end
	P:MoveTo(L.default_processor)
end

shift(0,0,0)
shift(5,5,5)
shift(-1,6,3)

