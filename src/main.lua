local abs = math.abs
local floor = math.floor
local max = math.max
local min = math.min
local sort = table.sort

local vehicle_types =
{
  ["locomotive"] = true,
  ["cargo-wagon"] = true,
  ["car"] = true,
}
local train_types =
{
  ["locomotive"] = true,
  ["cargo-wagon"] = true,
}
local default_masses =
{
  ["locomotive"] = LOCOMOTIVE_MASS,
  ["cargo-wagon"] = CARGO_WAGON_MASS,
  ["car"] = CAR_MASS,
}

-- Local function prototypes
local cache_equipment
local cars_tick
local charge_tick
local disable_train_braking
local disable_vehicle_braking
local enable_train_braking
local enable_vehicle_braking
local fuel_tick
local handle_train_state_change
local on_entity_removed
local on_train_removed
local on_entity_added
local read_equipment
local recover_energy
local update_equipment

-- Table utils
-------------------------------------------------------------------------------
-- These utilities assume the table is an array and each value is unique

local function insert_unique_f(tbl, x, f)
  for k, v in pairs(tbl) do
    if(f(v)) then
      return false
    end
  end
  tbl[#tbl + 1] = x
  return true
end

local function erase_f(tbl, f)
  for k, v in pairs(tbl) do
    if(f(v)) then
      tbl[k] = nil
      return k
    end
  end
  return nil
end

-- Local caches
-------------------------------------------------------------------------------

-- Dictionary of only those vehicles that have a transformer
-- [unit-number] = LuaEquipment
local transformer_for_unit = { }
-- Dictionary of only those vehicles that have a regenerative brake
-- [unit-number] = LuaEquipment
local regen_brake_for_unit = { }

-- Remember entities which were invalid in on_load to remove in the first on_tick
local invalid_entities = { }

function rebuild_caches()
  equipment_cache = { }
  transformer_for_unit = { }
  regen_brake_for_unit = { }
  
  for unit, entity in pairs(global.vehicles) do
    if(entity.valid) then
      local grid = entity.grid
      if(grid and grid.valid) then
        cache_equipment(unit, read_equipment(unit, grid))
      else
        invalid_entities[#invalid_entities + 1] = unit
      end
    else
      invalid_entities[#invalid_entities + 1] = unit
    end
  end
end

function validate_prototypes()
  -- Stop doing anything involving a no longer present prototypes
  local equipment = game.equipment_prototypes
  local entities = game.entity_prototypes
  for tbl, exists in pairs{[global.transformers] = equipment,
                           [global.brakes] = equipment} do
    for name in pairs(tbl) do
      if(not exists[name]) then
        tbl[name] = nil
      end
    end
  end
end

function validate_entities()
  -- If any units were deleted stop processing them
  for unit, entity in pairs(global.vehicles) do
    if(not entity.valid or not entity.grid) then
      global.vehicles[unit] = nil
    else
      -- In case equipment was deleted
      update_equipment(unit, entity.grid)
    end
  end
  -- Stop regeneration on deleted vehicles and trains
  for _, tbl in pairs{global.braking_vehicles, global.braking_trains} do
    for i, data in pairs(tbl) do
      if(not tbl[i][1].valid) then
        tbl[i] = nil
      end
    end
  end
end

-- Equipment handling
-------------------------------------------------------------------------------

read_equipment = function(unit, grid)
  local equipment = grid.equipment
  local known_transformers = global.transformers
  local known_brakes = global.brakes
  local transformers = { }
  local brakes = { }
  for i = 1, #equipment do
    local item = equipment[i]
    if(known_transformers[item.name] and item.prototype.energy_source) then
      transformers[#transformers + 1] = item
    elseif(known_brakes[item.name] and item.prototype.energy_source) then
      brakes[#brakes + 1] = item
    end
  end
  sort(transformers, function(a, b) return a.prototype.energy_source.input_flow_limit >
                                           b.prototype.energy_source.input_flow_limit end)
  sort(brakes, function(a, b) return known_brakes[a.name][2] >
                                     known_brakes[b.name][2] end)
  return transformers, brakes
end

cache_equipment = function(unit, transformers, brake)
  transformer_for_unit[unit] = transformers[1]
  regen_brake_for_unit[unit] = brake[1]
end

function update_equipment(unit, grid)
  local transformers, brakes = read_equipment(unit, grid)
  
  local entity = global.vehicles[unit]
  local had_brake = regen_brake_for_unit[unit] ~= nil
  cache_equipment(unit, transformers, brakes)

  -- If no transformer is present it's not an electric vehicle and cannot regen brake.
  local has_brake = brakes[1] and transformers[1]

  -- If the brake was removed disable regen braking.
  if(not has_brake and had_brake) then
    if(not train_types[entity.type]) then
      disable_vehicle_braking(entity)
    end
  elseif(not had_brake and has_brake) then
    if(entity.type == "car") then
      enable_vehicle_braking(entity)
    end
  end
end

-- on_tick actions
-------------------------------------------------------------------------------

fuel_tick = function()
  local vehicles = global.vehicles
  for unit, transformer in pairs(transformer_for_unit) do
    local entity = vehicles[unit]
    if(entity.valid) then
      local available_energy = transformer.energy
      local current_energy = entity.energy
      entity.energy = current_energy + available_energy
      -- The burner energy buffer is kinda weird so we have to check how much energy we actually inserted
      local used = entity.energy - current_energy
      transformer.energy = available_energy - used
    else
      vehicles[unit] = nil
      transformer_for_unit[unit] = nil
      regen_brake_for_unit[unit] = nil
      global.braking_vehicles[unit] = nil
    end
  end
end

recover_energy = function()
  local brakes = global.brakes
  for _, data in pairs(global.braking_trains) do
    local train = data[1]
    if(train.valid) then
      local previous_speed = data[2]
      local mass = data[3]
      local speed = train.speed * 60 -- convert m/tick to m/s
      local abs_speed = abs(speed)
      local difference = previous_speed - abs_speed
      if(difference > 0 and difference < 3) then
        -- Even though we use m/2 * v^2 using the direct game values isn't satisfactory so we do some magic number corrections.
        local gained = 0.5 * mass * (previous_speed * previous_speed - abs_speed * abs_speed) * 5
        local carriages = train.carriages
        -- All carriages participate in braking but only the locomotives recover energy.
        -- Optimally the distribution should be weighted by braking force participation.
        gained = gained / #carriages
        for i = 1, #carriages do
          local carriage = carriages[i]
          local brake = regen_brake_for_unit[carriage.unit_number]
          if(brake) then
            brake.energy = brake.energy + gained * brakes[brake.name][2]
          end
        end
      end
      data[2] = abs_speed
    else
      global.braking_trains[_] = nil
    end
  end
  for unit, data in pairs(global.braking_vehicles) do
    local entity = data[1]
    if(entity.valid) then
      local brake = regen_brake_for_unit[unit]
      local mass = data[3]
      if(brake) then
        local previous_speed = data[2]
        local speed = entity.speed * 60 -- convert m/tick to m/s
        local abs_speed = abs(speed)
        local difference = previous_speed - abs_speed
        if(difference > 0 and difference < 3) then
          local gained = 0.5 * mass * (previous_speed * previous_speed - abs_speed * abs_speed) * 5
          brake.energy = brake.energy + gained * brakes[brake.name][2]
        end
        data[2] = abs_speed
      end
    else
      global.vehicles[unit] = nil
      global.braking_vehicles[unit] = nil
      transformer_for_unit[unit] = nil
      regen_brake_for_unit[unit] = nil
    end
  end
end

-- Braking
-------------------------------------------------------------------------------

enable_vehicle_braking = function(entity)
  global.braking_vehicles[entity.unit_number] =
  {
    [1] = entity,
    [3] = entity.prototype.weight,
    [2] = entity.speed * 60, -- convert m/tick to m/s
  }
end

disable_vehicle_braking = function(entity)
  global.braking_vehicles[entity.unit_number] = nil
end

enable_train_braking = function(train)
  local mass = 0
  local carriages = train.carriages
  for i = 1, #carriages do
    mass = mass + carriages[i].prototype.weight
  end
  insert_unique_f(global.braking_trains,
                  {
                    [1] = train,
                    [2] = abs(train.speed * 60), -- convert m/tick to m/s
                    [3] = mass,
                  },
                  function(data) return data[1] == train end)
end

disable_train_braking = function(train)
  erase_f(global.braking_trains, function(data) return data[1] == train end)
end

-- Train specific
-------------------------------------------------------------------------------

handle_train_state_change = function(train)
  local state = train.state
  local braking = state == defines.train_state.path_lost or
                  state == defines.train_state.arrive_signal or
                  state == defines.train_state.arrive_station or
                  state == defines.train_state.manual_control_stop or
                  state == defines.train_state.manual_control or
                  state == defines.train_state.stop_for_auto_control
  if(braking) then
    enable_train_braking(train)
  else
    disable_train_braking(train)
  end
end

-- Entity management
-------------------------------------------------------------------------------

on_train_removed = function(train)
  disable_train_braking(train)
end

on_entity_removed = function(entity)
  if(train_types[entity.type]) then
    local train = entity.train
    if(train and #train.carriages <= 1) then
      on_train_removed(train)
    end
  end
  if(vehicle_types[entity.type]) then
    local unit = entity.unit_number
    global.vehicles[unit] = nil
    global.braking_vehicles[unit] = nil
    transformer_for_unit[unit] = nil
    regen_brake_for_unit[unit] = nil
  end
end

on_entity_added = function(entity)
  if(entity and entity.valid) then
    if(vehicle_types[entity.type] and entity.grid) then
      global.vehicles[entity.unit_number] = entity
      update_equipment(entity.unit_number, entity.grid)
    end
  end
end

-- Event entry points
-------------------------------------------------------------------------------

function on_built_entity(event)
  local entity = event.created_entity
  on_entity_added(entity)
end

function script_raised_built(event)
  local entity = event.entity  -- script_raised has different structure than on_built
  on_entity_added(entity)
end

function on_entity_died(event)
  on_entity_removed(event.entity)
end

function on_player_placed_equipment(event)
  for unit, entity in pairs(global.vehicles) do
    if(entity.valid) then
      if(entity.grid == event.grid) then
        update_equipment(unit, event.grid)
        break
      end
    else
      global.vehicles[unit] = nil
      global.braking_vehicles[unit] = nil
      transformer_for_unit[unit] = nil
      regen_brake_for_unit[unit] = nil
    end
  end
end

function on_player_removed_equipment(event)
  for unit, entity in pairs(global.vehicles) do
    if(entity.valid) then
      if(entity.grid == event.grid) then
        update_equipment(unit, event.grid)
        break
      end
    else
      global.vehicles[unit] = nil
      global.braking_vehicles[unit] = nil
      transformer_for_unit[unit] = nil
      regen_brake_for_unit[unit] = nil
    end
  end
end

function on_preplayer_mined_item(event)
  on_entity_removed(event.entity)
end

function on_robot_pre_mined(event)
  on_entity_removed(event.entity)
end

function on_tick(event)
  function real_on_tick(event)
    fuel_tick()
    recover_energy()
  end
  
  for _, unit in pairs(invalid_entities) do
    global.vehicles[unit] = nil
    global.braking_vehicles[unit] = nil
  end
  for index, data in pairs(global.braking_trains) do
    if(not data[1].valid) then
      global.braking_trains[index] = nil
    end
  end
  invalid_entities = { }
  script.on_event(defines.events.on_tick, real_on_tick)
  real_on_tick(event)
end

function on_train_changed_state(event)
  handle_train_state_change(event.train)
end

-- Remote interface
-------------------------------------------------------------------------------

function register_transformer(data)
  assert(type(data.name) == "string", "'name' must be a string")
  local prototype = game.equipment_prototypes[data.name]
  assert(prototype, string.format("%s is not a valid equipment prototype", data.name))
  assert(prototype.energy_source, string.format("%s has no energy_source", data.name))
  global.transformers[data.name] =
  {
    [1] = data.name,
    [2] = prototype.energy_source.input_flow_limit,
  }
end

function register_brake(data)
  assert(type(data.name) == "string", "'name' must be a string")
  assert(game.equipment_prototypes[data.name], string.format("%s is not a valid equipment prototype", data.name))
  assert(type(data.efficiency) == "number" and data.efficiency >= 0 and data.efficiency <= 1,
         "brake efficiency must be a number in the range [0,1]")
  global.brakes[data.name] =
  {
    [1] = data.name,
    [2] = data.efficiency,
  }
end
