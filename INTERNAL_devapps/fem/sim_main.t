import "ebb"
local L = require "ebblib"
local vdb = require 'ebb.lib.vdb'

local Tetmesh = require 'INTERNAL_devapps.fem.tetmesh'
local VEGFileIO = require 'INTERNAL_devapps.fem.vegfileio'
local PN = require 'ebb.lib.pathname'
local U = require 'INTERNAL_devapps.fem.utils'

--------------------------------------------------------------------------------
--[[                  Setup mesh, simulation paramters etc                  ]]--
--------------------------------------------------------------------------------

local function printUsageAndExit()
  print("Usage : ./ebb [-gpu] INTERNAL_devapps/fem/view-files.t <options>")
  print("          -config <config file with additional information> (** required **)")
  print("          -force <stvk or nh>")
  print("          -steps <number of time steps>")
  os.exit(1)
end

-- default values for options
local configFileName = nil
local forceModel = 'stvk'
local numTimeSteps = 5
local cudaProfile = false

if #arg < 2 then
  printUsageAndExit()
else
  for i=1,#arg,2 do
    if arg[i] == '-config' then
      configFileName = arg[i+1]
    elseif arg[i] == '-force' then
      forceModel = arg[i+1]
    elseif arg[i] == '-steps' then
      numTimeSteps = tonumber(arg[i+1])
    elseif arg[i] == '-cuda_profile' then
      cudaProfile = (arg[i+1] == 'true')
    else
      printUsageAndExit()
    end
  end
  if not configFileName then
    print("Config file name required")
    printUsageAndExit()
  end
end

local configFile = loadfile(configFileName)()

local meshFileName = configFile.meshFileName
print("Loading " .. meshFileName)
local mesh   = VEGFileIO.LoadTetmesh(meshFileName)
mesh.density = configFile.rho
mesh.E       = configFile.E
mesh.Nu      = configFile.Nu
mesh.lambdaLame = mesh.Nu * mesh.E / ( ( 1.0 + mesh.Nu ) * ( 1.0 - 2.0 * mesh.Nu ) )
mesh.muLame     = mesh.E / ( 2.0 * ( 1.0 + mesh.Nu) )

local I = nil
if cudaProfile then
  I = terralib.includecstring([[ #include "cuda_profiler_api.h"]])
end

local gravity = 9.81

print("Number of edges : " .. tostring(mesh.edges:Size() .. "\n"))

function initConfigurations()
  local options = {
    timestep                    = configFile.timestep or 0.1,
    dampingMassCoef             = configFile.dampingMassCoeff or 1.0,
    dampingStiffnessCoef        = configFile.dampingStiffnessCoeff or 0.01,
    deformableObjectCompliance  = configFile.deformableObjectCompliance or 1.0,

    maxIterations               = configFile.maxIterations or 1,
    epsilon                     = configFile.epsilon or 1e-6,
    numTimesteps                = numTimeSteps,

    cgEpsilon                   = 1e-6,
    cgMaxIterations             = 10000
  }
  return options
end


--------------------------------------------------------------------------------
--[[          Allocate/ initialize/ set/ access common mesh data            ]]--
--------------------------------------------------------------------------------

mesh.edges:NewField('stiffness', L.mat3d)
mesh.edges:NewField('mass', L.double):Load(0)
mesh.tetrahedra:NewField('volume', L.double)
mesh.vertices:NewField('q', L.vec3d):Load({ 0, 0, 0})
mesh.vertices:NewField('qvel', L.vec3d):Load({ 0, 0, 0 })
mesh.vertices:NewField('qaccel', L.vec3d):Load({ 0, 0, 0 })
mesh.vertices:NewField('external_forces', L.vec3d):Load({ 0, 0, 0 })
mesh.vertices:NewField('internal_forces', L.vec3d):Load({0, 0, 0})

-- stvk or neohookean
local F = nil
local outDirName = nil
if forceModel == 'stvk' then
  F = require 'INTERNAL_devapps.fem.stvk'
  outDirName = 'ebb_output/stvk-out'
  os.execute('mkdir -p INTERNAL_devapps/fem/' .. outDirName)
else
  F = require 'INTERNAL_devapps.fem.neohookean'
  outDirName = 'ebb_output/nh-out'
  os.execute('mkdir -p INTERNAL_devapps/fem/' .. outDirName)
end
F.profile = false  -- measure and print out detailed timing?


--------------------------------------------------------------------------------
--[[                     Helper functions and kernels                       ]]--
--------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- For corresponding VEGA code, see
--    libraries/volumetricMesh/generateMassMatrix.cpp (computeMassMatrix)
--    libraries/volumetricMesh/tetMesh.cpp (computeElementMassMatrix)

-- The following implemfntation combines computing element matrix and updating
-- global mass matrix, for convenience.
-- Also, it corresponds to inflate3Dim=False.
-- Inflate3Dim adds the same entry for each dimension, in the implementation
-- at libraries/volumetricMesh/generateMassMatrix.cpp. This is redundant,
-- unless the mass matrix is modified in a different way for each dimension
-- sometime later. What should we do??

function computeMassMatrix(mesh)
  -- Q: Is inflate3Dim flag on?
  -- A: Yes.  This means we want the full mass matrix,
  --    not just a uniform scalar per-vertex
  local ebb buildMassMatrix (t : mesh.tetrahedra)
    var tet_vol = L.fabs(t.elementDet)/6
    var factor = tet_vol * t.density/ 20
    for i = 0,4 do
      for j = 0,4 do
        var mult_const = 1
        if i == j then
          mult_const = 2
        end
        t.e[i, j].mass += factor * mult_const
      end
    end
  end
  mesh.tetrahedra:foreach(buildMassMatrix)
end


--------------------------------------------------------------------------------
--[[                        Integration + CG solver                         ]]--
--------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Implicit backward euler
local ImplicitBackwardEulerIntegrator = {}
ImplicitBackwardEulerIntegrator.__index = ImplicitBackwardEulerIntegrator

-- integrator options
function ImplicitBackwardEulerIntegrator.New(opts)
  local stepper = setmetatable({
    internalForcesScalingFactor  = opts.internalForcesScalingFactor,
    epsilon                     = opts.epsilon,
    timestep                    = opts.timestep,
    dampingMassCoef             = opts.dampingMassCoef,
    dampingStiffnessCoef        = opts.dampingStiffnessCoef,
    maxIterations               = opts.maxIterations,
    cgEpsilon                   = opts.cgEpsilon,
    cgMaxIterations             = opts.cgMaxIterations
  }, ImplicitBackwardEulerIntegrator)

  return stepper
end


------------------------------------------------------------------------------
-- Set up integrator functions/ kernels to do a time step
function ImplicitBackwardEulerIntegrator:setupFieldsFunctions(mesh)

  -- these fields are not used outside the integrator
  mesh.vertices:NewField('q_1', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('qvel_1', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('qaccel_1', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('qresidual', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('qvdelta', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('precond', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('x', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('r', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('z', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('p', L.vec3d):Load({ 0, 0, 0 })
  mesh.vertices:NewField('Ap', L.vec3d):Load({ 0, 0, 0 })
  if self.useDamp then
    mesh.edges:NewField('raydamp', L.mat3d)
  end

  self.err = L.Global(L.double, 0)
  self.normRes = L.Global(L.double, 0)
  self.alphaDenom = L.Global(L.double, 0)
  self.alpha = L.Global(L.double, 0)
  self.beta = L.Global(L.double, 0)

  ebb self.initializeQFields (v : mesh.vertices)
    v.q_1 = v.q
    v.qvel_1 = v.qvel
    v.qaccel = { 0, 0, 0 }
    v.qaccel_1 = { 0, 0, 0 }
  end

  ebb self.initializeqvdelta (v : mesh.vertices)
    v.qvdelta = v.qresidual
  end

  ebb self.scaleInternalForces (v : mesh.vertices)
    v.internal_forces = self.internalForcesScalingFactor * v.internal_forces
  end

  ebb self.scaleStiffnessMatrix (e : mesh.edges)
    e.stiffness = self.internalForcesScalingFactor * e.stiffness
  end

  if self.useDamp then
    ebb self.createRayleighDampMatrix (e : mesh.edges)
      e.raydamp = self.dampingStiffnessCoef * e.stiffness +
                  U.diagonalMatrix(self.dampingMassCoef * e.mass)
    end
  else
    ebb self.createRayleighDampMatrix (e : mesh.edhes)
    end
  end

  ebb self.updateqresidual1 (v : mesh.vertices)
    for e in v.edges do
      v.qresidual += U.multiplyMatVec3(e.stiffness, (e.head.q_1 - e.head.q))
    end
  end

  ebb self.updateqresidual2 (v : mesh.vertices)
    for e in v.edges do
      v.qresidual += U.multiplyMatVec3(e.stiffness, e.head.qvel)
    end
  end

  ebb self.updateqresidual3 (v : mesh.vertices)
    v.qresidual += (v.internal_forces - v.external_forces)
    v.qresidual = - ( self.timestep * v.qresidual )
  end

  ebb self.updateqresidual4 (v : mesh.vertices)
    for e in v.edges do
      v.qresidual += e.mass * (e.head.qvel_1 - e.head.qvel)
    end
  end

  if self.useDamp then
    ebb self.updateStiffness1 (e : mesh.edges)
      e.stiffness = self.timestep * e.stiffness
      e.stiffness += e.raydamp
    end
  else
    ebb self.updateStiffness1 (e : mesh.edges)
      e.stiffness = self.timestep * e.stiffness
    end
  end

  ebb self.updateStiffness11 (e : mesh.edges)
    e.stiffness = self.timestep * e.stiffness
  end

  if self.useDamp then
    ebb self.updateStiffness12 (e : mesh.edges)
      e.stiffness += e.raydamp
    end
  else
    ebb self.updateStiffness12 (e : mesh.edges)
    end
  end

  ebb self.updateStiffness2 (e : mesh.edges)
    e.stiffness = self.timestep * e.stiffness
    e.stiffness += U.diagonalMatrix(e.mass)
  end

  ebb self.getError (v : mesh.vertices)
    var qd = v.qvdelta
    var err = L.dot(qd, qd)
    self.err += err
  end

  ebb self.pcgCalculatePreconditioner (v : mesh.vertices)
    var stiff = v.diag.stiffness
    var diag = { stiff[0,0], stiff[1,1], stiff[2,2] }
    v.precond = { 1.0/diag[0], 1.0/diag[1], 1.0/diag[2] }
  end

  ebb self.pcgCalculateExactResidual (v : mesh.vertices)
    v.r = { 0, 0, 0 }
    for e in v.edges do
      v.r += U.multiplyMatVec3(e.stiffness, e.head.x)
    end
    v.r = v.qvdelta - v.r
  end

  ebb self.pcgCalculateNormResidual (v : mesh.vertices)
    self.normRes += L.dot(U.multiplyVectors(v.r, v.precond), v.r)
  end

  ebb self.pcgInitialize (v : mesh.vertices)
    v.p = U.multiplyVectors(v.r, v.precond)
  end

  ebb self.pcgComputeAp (v : mesh.vertices)
    var Ap : L.vec3d = { 0, 0, 0 }
    for e in v.edges do
      var A = e.stiffness
      var p = e.head.p
      Ap += U.multiplyMatVec3(A, p)
    end
    v.Ap = Ap
  end

  ebb self.pcgComputeAlphaDenom (v : mesh.vertices)
    self.alphaDenom += L.dot(v.p, v.Ap)
  end

  ebb self.pcgUpdateX (v : mesh.vertices)
    v.x += self.alpha * v.p
  end

  ebb self.pcgUpdateResidual (v : mesh.vertices)
    v.r -= self.alpha * v.Ap
  end

  ebb self.pcgUpdateP (v : mesh.vertices)
    v.p = self.beta * v.p + U.multiplyVectors(v.precond, v.r)
  end

  ebb self.updateAfterSolve (v : mesh.vertices)
    v.qvdelta = v.x
    v.qvel += v.qvdelta
    -- TODO: subtracting q from q?
    -- q += q_1-q + self.timestep * qvel
    v.q = v.q_1 + self.timestep * v.qvel
  end

end


------------------------------------------------------------------------------
-- PCG solver with Jacobi preconditioner, as implemented in Vega
-- It uses the same algorithm as Vega (exact residual on 30th iteration). But
-- the symbol names are kept to match the pseudo code on Wikipedia for clarity.
function ImplicitBackwardEulerIntegrator:solvePCG(mesh)
  if I then I.cudaProfilerStart() end
  local timer_solver = U.Timer.New()
  timer_solver:Start()
  mesh.vertices.x:Load({ 0, 0, 0 })
  mesh.vertices:foreach(self.pcgCalculatePreconditioner, {blocksize=16})
  local iter = 1
  mesh.vertices:foreach(self.pcgCalculateExactResidual, {blocksize=16})
  self.normRes:set(0)
  mesh.vertices:foreach(self.pcgInitialize, {blocksize=16})
  mesh.vertices:foreach(self.pcgCalculateNormResidual, {blocksize=16})
  local normRes = self.normRes:get()
  local thresh = self.cgEpsilon * self.cgEpsilon * normRes
  while normRes > thresh and
        iter <= self.cgMaxIterations do
    mesh.vertices:foreach(self.pcgComputeAp, {blocksize=16})
    self.alphaDenom:set(0)
    mesh.vertices:foreach(self.pcgComputeAlphaDenom, {blocksize=64})
    self.alpha:set( normRes / self.alphaDenom:get() )
    mesh.vertices:foreach(self.pcgUpdateX, {blocksize=64})
    if iter % 30 == 0 then
      mesh.vertices:foreach(self.pcgCalculateExactResidual, {blocksize=16})
    else
      mesh.vertices:foreach(self.pcgUpdateResidual, {blocksize=64})
    end
    local normResOld = normRes
    self.normRes:set(0)
    mesh.vertices:foreach(self.pcgCalculateNormResidual, {blocksize=64})
    normRes = self.normRes:get()
    self.beta:set( normRes / normResOld )
    mesh.vertices:foreach(self.pcgUpdateP, {blocksize=64})
    iter = iter + 1
  end
  if normRes > thresh then
      print("Residual is ", normRes)
      error("PCG solver did not converge!")
  end
  print("Time for solver is "..(timer_solver:Stop()*1E6).." us")
  if I then I.cudaProfilerStop() end
end


------------------------------------------------------------------------------
-- Function that does one iteration of integrator
function ImplicitBackwardEulerIntegrator:doTimestep(mesh)

  local err0 = 0 -- L.Global?
  local errQuotient

  -- store current amplitudes and set initial gues for qaccel, qvel
  mesh.vertices:foreach(self.initializeQFields)

  -- Limit our total number of iterations allowed per timestep
  for numIter = 1, self.maxIterations do

    F.computeInternalForcesAndStiffnessMatrix(mesh)

    mesh.vertices:foreach(self.scaleInternalForces)
    mesh.edges:foreach(self.scaleStiffnessMatrix)

    -- ZERO out the residual field
    mesh.vertices.qresidual:Load({ 0, 0, 0 })

    -- NOTE: useStaticSolver == FALSE
    --    We just assume this everywhere
    mesh.edges:foreach(self.createRayleighDampMatrix)

    -- Build effective stiffness:
    --    Keff = M + h D + h^2 * K
    -- compute force residual, store it into aux variable qresidual
    -- Semi-Implicit Euler
    --    qresidual = h * (-D qdot - fint + fext - h * K * qdot)
    -- Fully-Implicit Euler
    --    qresidual = M (qvel_1-qvel) +
    --                h * (-D qdot - fint + fext - K * (q_1 - q + h * qdot))

    -- superfluous on iteration 1, but safe to run
    if numIter ~= 1 then
      mesh.vertices:foreach(self.updateqresidual1)
    end

    -- some magic incantations corresponding to the above
    mesh.edges:foreach(self.updateStiffness11)
    mesh.edges:foreach(self.updateStiffness12)
    mesh.vertices:foreach(self.updateqresidual2)
    mesh.edges:foreach(self.updateStiffness2)

    -- Add external/ internal internal_forces
    mesh.vertices:foreach(self.updateqresidual3)

    -- superfluous on iteration 1, but safe to run
    if numIter ~= 1 then
      mesh.vertices:foreach(self.updateqresidual4)
    end

    -- TODO: this should be a copy and not a separate function in the end
    mesh.vertices:foreach(self.initializeqvdelta)

    -- TODO: This code doesn't have any way of handling fixed vertices
    -- at the moment.  Should enforce that here somehow
    self.err:set(0)
    mesh.vertices:foreach(self.getError)

    -- compute initial error on the 1st iteration
    if numIter == 1 then
      err0 = self.err:get()
      errQuotient = 1
    else
      errQuotient = self.err:get() / err0
    end

    if errQuotient < self.epsilon*self.epsilon or
      err0 < self.epsilon*self.epsilon then
      break
    end

    self:solvePCG(mesh)

    -- Reinsert the rows?

    mesh.vertices:foreach(self.updateAfterSolve)

    -- Constrain (zero) fields for the subset of constrained vertices
  end
end


--------------------------------------------------------------------------------
--[[                 Set up forces and run the simulation                   ]]--
--------------------------------------------------------------------------------

function clearExternalForces(mesh)
  mesh.vertices.external_forces:Load({ 0, 0, 0 })
end

local setExternalForces = nil

local ebb setExternalForcesStvk (v : mesh.vertices)
  var pos = v.pos
  v.external_forces = { 10.0, -0.8*pos[1], 0 }
end

local ebb setExternalForcesNh (v : mesh.vertices)
    v.external_forces = { 5.0, 0, 0 }
end

if forceModel == 'stvk' then
    setExternalForces = setExternalForcesStvk
else
    setExternalForces = setExternalForcesNh
end

function setExternalConditions(mesh, iter)
  if iter == 1 then
    mesh.vertices:foreach(setExternalForces)
  end
end

function main()
  local options = initConfigurations()

  local volumetric_mesh = mesh

  local nvertices = volumetric_mesh:nVerts()
  -- No fixed vertices for now
  local numFixedVertices = 0
  local numFixedDOFs     = 0
  local fixedDOFs        = nil

  --[[
  local maxdegree = L.Global(L.double, 0)
  local mindegree = L.Global(L.double, math.huge)
  mesh.vertices:foreach( ebb ( v )
    var d = -1
    for e in v.edges do d = d + 1 end
    maxdegree max= d
  end)
  mesh.vertices:foreach( ebb ( v )
    var d = -1
    for e in v.edges do d = d + 1 end
    mindegree min= d
  end)
  print('min degree: ', mindegree:get())
  print('max degree: ', maxdegree:get())
  print('avg degree: ', mesh.edges:Size() / mesh.vertices:Size() - 1)
  --]]

  computeMassMatrix(volumetric_mesh)

  F:setupFieldsFunctions(mesh)

  local integrator = ImplicitBackwardEulerIntegrator.New{
    n_vars                = 3*nvertices,
    timestep              = options.timestep,
    positiveDefinite      = 0,
    nFixedDOFs            = 0,
    dampingMassCoef       = options.dampingMassCoef,
    dampingStiffnessCoef  = options.dampingStiffnessCoef,
    maxIterations         = options.maxIterations,
    epsilon               = options.epsilon,
    cgEpsilon             = options.cgEpsilon,
    cgMaxIterations       = options.cgMaxIterations,
    internalForcesScalingFactor  = options.deformableObjectCompliance
  }
  -- integrator.useDamp = (forceModel == 'stvk')
  integrator.useDamp = true
  integrator:setupFieldsFunctions(mesh)

  mesh:dumpDeformationToFile(outDirName.."/vertices_"..tostring(0))

  local timer_step = U.Timer.New()
  for i=1,options.numTimesteps do
    timer_step:Start()
    setExternalConditions(volumetric_mesh, i)
    integrator:doTimestep(volumetric_mesh)
    print("Time for step "..i.." is "..(timer_step:Stop()*1E6).." us\n")
    mesh:dumpDeformationToFile(outDirName..'/vertices_'..tostring(i))
  end

  -- Output frame number and mesh file for viewing later on
  local numFramesFile = io.open('INTERNAL_devapps/fem/' .. outDirName..'/num_frames', 'w')
  numFramesFile:write(tostring(numTimeSteps))
  numFramesFile:close()
  os.execute('cp ' .. meshFileName .. ' ' .. 'INTERNAL_devapps/fem/' .. outDirName .. '/mesh')
end

main()
