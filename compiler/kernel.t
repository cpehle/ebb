local K = {}
package.loaded["compiler.kernel"] = K

-- Use the following to produce
-- deterministic order of table entries
-- From the Lua Documentation
function pairs_sorted(tbl, compare)
  local arr = {}
  for k in pairs(tbl) do table.insert(arr, k) end
  table.sort(arr, compare)

  local i = 0
  local iter = function() -- iterator
    i = i + 1
    if arr[i] == nil then return nil
    else return arr[i], tbl[arr[i]] end
  end
  return iter
end


local L = terralib.require "compiler.lisztlib"

local specialization = terralib.require "compiler.specialization"
local semant         = terralib.require "compiler.semant"
local phase          = terralib.require "compiler.phase"
local codegen        = terralib.require "compiler.codegen"

local DataArray = terralib.require('compiler.rawdata').DataArray


-------------------------------------------------------------------------------
--[[ Kernels, Brans, Germs                                                 ]]--
-------------------------------------------------------------------------------
--[[

We use a Kernel as the primary unit of computation.
  For internal use, we define the related concepts of Germ and Bran

((
etymology:
  a Germ is the plant embryo within a kernel,
  a Bran is the outer part of a kernel, encasing the germ and endosperm
))

A Germ -- a Terra struct.
          It provides a dynamic context at execution time.
          Example entries:
            - number of rows in the relation
            - subset masks
            - field data pointers

A Bran -- a Lua table
          It provides metadata about a particular kernel specialization.
          e.g. one bran for each (kernel, runtime, subset) tuple
          Examples entries:
            - signature params: (relation, subset)
            - a germ
            - executable function
            - field/phase signature

Each Kernel may have many Brans, each a compile-time specialization
Each Bran may have a different assignment of Germ values for each execution

]]--

local Bran = {}
Bran.__index = Bran

function Bran.New()
  return setmetatable({}, Bran)
end

-- Seedbank is a cache of brans
local Seedbank = {}
local function seedbank_lookup(sig)
  local str_sig = ''
  for k,v in pairs_sorted(sig) do
    str_sig = str_sig .. k .. '=' .. tostring(v) .. ';'
  end
  local bran = Seedbank[str_sig]
  if not bran then
    bran = Bran.New()
    for k,v in pairs(sig) do bran[k] = v end
    Seedbank[str_sig] = bran
  end
  return bran
end



-------------------------------------------------------------------------------
--[[ Germs                                                                 ]]--
-------------------------------------------------------------------------------

-- Create a Germ Lua Object that generates the needed Terra structure
local GermTemplate = {}
GermTemplate.__index = GermTemplate

function GermTemplate.New()
  return setmetatable({
    fields    = terralib.newlist(),
    globals   = terralib.newlist(),
  }, GermTemplate)
end

function GermTemplate:addField(name, typ)
  table.insert(self.fields, { field=name, type=&typ })
end

function GermTemplate:addGlobal(name, typ)
  table.insert(self.globals, { field=name, type=&typ })
end

function GermTemplate:turnSubsetOn()
  self.subset_on = true
end

function GermTemplate:addInsertion()
  self.insert_on = true
end

local taddr = uint64 --L.addr:terraType() -- weird dependency error
function GermTemplate:TerraStruct()
  if self.terrastruct then return self.terrastruct end
  local terrastruct = terralib.types.newstruct(self.name)

  -- add counter
  table.insert(terrastruct.entries, {field='n_rows', type=uint64})
  -- add subset data
  if self.subset_on then
    table.insert(terrastruct.entries, {field='use_boolmask', type=bool})
    table.insert(terrastruct.entries, {field='boolmask',     type=&bool})
    table.insert(terrastruct.entries, {field='index',        type=&taddr})
    table.insert(terrastruct.entries, {field='index_size',   type=uint64})
  end
  if self.insert_on then
    table.insert(terrastruct.entries, {field='insert_write', type=uint64})
  end
  -- add fields
  for _,v in ipairs(self.fields) do table.insert(terrastruct.entries, v) end
  -- add globals
  for _,v in ipairs(self.globals) do table.insert(terrastruct.entries, v) end

  self.terrastruct = terrastruct
  return terrastruct
end

function GermTemplate:isGenerated()
  return self.terrastruct ~= nil
end



-------------------------------------------------------------------------------
--[[ Kernels                                                               ]]--
-------------------------------------------------------------------------------


function L.NewKernel(kernel_ast, env)
    local new_kernel = setmetatable({}, L.LKernel)

    -- All declaration time processing here
    local specialized    = specialization.specialize(env, kernel_ast)
    new_kernel.typed_ast = semant.check(env, specialized)

    local phase_results   = phase.phasePass(new_kernel.typed_ast)
    new_kernel.field_use  = phase_results.field_use
    new_kernel.global_use = phase_results.global_use
    new_kernel.inserts    = phase_results.inserts
    new_kernel.deletes    = phase_results.deletes

    return new_kernel
end


L.LKernel.__call  = function (kobj, relset)
    if not (relset and (L.is_relation(relset) or L.is_subset(relset)))
    then
        error("A kernel must be called on a relation or subset.", 2)
    end

    local proc = L.default_processor

    -- retreive the correct bran or create a new one
    local bran = seedbank_lookup({
        kernel=kobj,
        relset=relset,
        proc=proc,
    })
    if not bran.executable then
      bran.relset = relset
      bran.kernel = kobj
      bran.location = proc
      bran:generate()
    end

    -- determine whether or not this kernel invocation is
    -- safe to run or not.
    bran:dynamicChecks()


    -- set execution parameters in the germ
    local cpu_germ    = bran.cpu_germ:ptr()
    cpu_germ.n_rows   = bran.relation:ConcreteSize()
    -- bind the subset data
    if bran.subset then
      cpu_germ.use_boolmask     = false
      if bran.subset then
        if bran.subset._boolmask then
          cpu_germ.use_boolmask = true
          cpu_germ.boolmask     = bran.subset._boolmask:DataPtr()
        elseif bran.subset._index then
          cpu_germ.index        = bran.subset._index:DataPtr()
          cpu_germ.index_size   = bran.subset._index:Size()
        else
          assert(false)
        end
      end
    end
    -- bind insert data
    if bran.insert_data then
      local insert_rel            = bran.insert_data.relation
      local center_size_logical   = bran.relation:Size()
      local insert_size_concrete  = insert_rel:ConcreteSize()

      bran.insert_data.n_inserted:set(0)
      -- cache the old size
      bran.insert_data.last_concrete_size = insert_size_concrete
      -- set the write head to point to the end of array
      cpu_germ.insert_write = insert_size_concrete
      -- resize to create more space at the end of the array
      insert_rel:ResizeConcrete(insert_size_concrete +
                                center_size_logical)
    end
    -- bind delete data (just a global here)
    if bran.delete_data then
      local relsize = bran.delete_data.relation._logical_size
      bran.delete_data.updated_size:set(relsize)
    end
    -- bind the field data (MUST COME LAST)
    for field, _ in pairs(bran.field_ids) do
      bran:setCPUField(field)
    end
    for globl, _ in pairs(bran.global_ids) do
      bran:setCPUGlobal(globl)
    end
    -- Load the germ data into the runtime location
    if bran.runtime_germ:location() == L.GPU then
      bran.runtime_germ:copy(bran.cpu_germ)
    end

    -- launch the kernel
    bran.executable()

    -- adjust sizes based on extracted information
    if bran.insert_data then
      local insert_rel        = bran.insert_data.relation
      local old_concrete_size = bran.insert_data.last_concrete_size
      local old_logical_size  = insert_rel._logical_size
      local n_inserted        = bran.insert_data.n_inserted:get()

      -- shrink array back down to where we actually ended up writing
      local new_concrete_size = old_concrete_size + n_inserted
      insert_rel:ResizeConcrete(new_concrete_size)
      -- update the logical view of the size
      insert_rel._logical_size = old_logical_size + n_inserted

      -- NOTE that this relation is definitely fragmented now
      bran.insert_data.relation._typestate.fragmented = true
    end
    if bran.delete_data then
      local updated_size = bran.delete_data.updated_size:get()
      bran.delete_data.relation._logical_size = updated_size
      bran.delete_data.relation._typestate.fragmented = true
    end
end


-------------------------------------------------------------------------------
--[[ Brans                                                                 ]]--
-------------------------------------------------------------------------------


function Bran:generate()
  local bran      = self
  local kernel    = bran.kernel
  local typed_ast = bran.kernel.typed_ast

  -- break out the arguments
  if L.is_relation(bran.relset) then
    bran.relation = bran.relset
  else
    bran.relation = bran.relset:Relation()
    bran.subset   = bran.relset
  end

  -- type checking the kernel signature against the invocation
  if typed_ast.relation ~= bran.relation then
      error('Kernels may only be called on a relation they were typed with')
  end

  bran.germ_template = GermTemplate.New()

  -- fix the mapping for the fields before compiling the executable
  bran.field_ids    = {}
  bran.n_field_ids  = 0
  for field, _ in pairs(kernel.field_use) do
    bran:getFieldId(field)
  end
  bran:getFieldId(bran.relation._is_live_mask)
  -- fix the mapping for the globals before compiling the executable
  bran.global_ids   = {}
  bran.n_global_ids = 0
  for globl, _ in pairs(kernel.global_use) do
    bran:getGlobalId(globl)
  end
  -- setup subsets?
  if bran.subset then bran.germ_template:turnSubsetOn() end

  -- setup insert and delete
  if kernel.inserts then
    bran:generateInserts()
  end
  if kernel.deletes then
    bran:generateDeletes()
  end


  -- allocate memory for 1-2 copies of the germ
  bran.cpu_germ = DataArray.New{
    size = 1,
    type = bran.germ_template:TerraStruct(),
    processor = L.CPU -- DON'T MOVE
  }
  bran.runtime_germ = bran.cpu_germ
  if bran.location == L.GPU then
    bran.runtime_germ = DataArray.New{
      size = 1,
      type = bran.germ_template:TerraStruct(),
      processor = L.GPU,  -- DON'T MOVE
    }
  end

  -- compile an executable
  bran.executable = codegen.codegen(typed_ast, bran)
end

function Bran:getFieldId(field)
  local id = self.field_ids[field]
  if not id then
    if self.germ_template:isGenerated() then
      error('INTERNAL ERROR: cannot add new fields after struct gen')
    end
    id = 'field_'..tostring(self.n_field_ids)..'_'..field:Name()
    self.n_field_ids = self.n_field_ids+1

    self.field_ids[field] = id
    self.germ_template:addField(id, field:Type():terraType())
  end
  return id
end

function Bran:getGlobalId(global)
  local id = self.global_ids[global]
  if not id then
    if self.germ_template:isGenerated() then
      error('INTERNAL ERROR: cannot add new globals after struct gen')
    end
    id = 'global_'..tostring(self.n_global_ids) -- no global names
    self.n_global_ids = self.n_global_ids+1

    self.global_ids[global] = id
    self.germ_template:addGlobal(id, global.type:terraType())
  end
  return id
end

function Bran:setCPUField(field)
  local id = self:getFieldId(field)
  local dataptr = field:DataPtr()
  self.cpu_germ:ptr()[id] = dataptr
end
function Bran:setCPUGlobal(global)
  local id = self:getGlobalId(global)
  local dataptr = global:DataPtr()
  self.cpu_germ:ptr()[id] = dataptr
end
function Bran:getRuntimeFieldPtr(field)
  local id = self:getFieldId(field)
  return `[self.runtime_germ:ptr()].[id]
end
function Bran:getRuntimeGlobalPtr(global)
  local id = self:getGlobalId(global)
  return `[self.runtime_germ:ptr()].[id]
end

function Bran:dynamicChecks()
  -- Check that the fields are resident on the correct processor
  -- TODO(crystal)  - error message here can be confusing.  For example, the
  -- dynamic check may report an error on the location of a field generated by a
  -- liszt library.  Since the user is not aware of how/when the field was
  -- generated, this makes it hard to determine how to fix the error.  Perhaps we
  -- should report *all* incorrectly located fields? Or at least prefer printing
  -- fields that are not prefaced with an underscore?
  for field, _ in pairs(self.field_ids) do
    if field.array:location() ~= self.location then
      error("cannot execute kernel because field "..field:FullName()..
            " is not currently located on "..tostring(self.location), 3)
    end
  end

  if self.insert_data then 
    if self.location ~= L.CPU then
      error("insert statement is currently only supported in CPU-mode.", 3)
    end
    local rel = self.insert_data.relation
    local unsafe_msg = rel:UnsafeToInsert(self.insert_data.record_type)
    if unsafe_msg then error(unsafe_msg, 3) end
  end
  if self.delete_data then
    if self.location ~= L.CPU then
      error("delete statement is currently only supported in CPU-mode.", 3)
    end
    local unsafe_msg = self.delete_data.relation:UnsafeToDelete()
    if unsafe_msg then error(unsafe_msg, 3) end
  end
end


function Bran:generateInserts()
  local bran = self
  assert(bran.location == L.CPU)

  local rel, ast_nodes = next(bran.kernel.inserts)
  bran.insert_data = {
    relation = rel,
    record_type = ast_nodes[1].record_type,
    n_inserted  = L.NewGlobal(L.addr, 0),
  }
  -- register the global variable
  bran:getGlobalId(bran.insert_data.n_inserted)

  -- prep all the fields we want to be able to write to.
  for _,field in ipairs(rel._fields) do
    bran:getFieldId(field)
  end
  bran:getFieldId(rel._is_live_mask)
  bran.germ_template:addInsertion()
end

function Bran:generateDeletes()
  local bran = self
  assert(bran.location == L.CPU)

  local rel = next(bran.kernel.deletes)
  bran.delete_data = {
    relation = rel,
    updated_size = L.NewGlobal(L.addr, 0)
  }
  -- register global variable
  bran:getGlobalId(bran.delete_data.updated_size)
end












