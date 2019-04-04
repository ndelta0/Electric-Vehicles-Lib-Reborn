require("src.main")
require("remote")

local function on_init()
  -- Working set
  
  -- List of all known vehicles with an equipment grid
  -- [unit-number] = entity
  global.vehicles = { }
  -- List of all trains currently slowing down. Used for regenerative braking.
  -- [*] = braking data
  global.braking_trains = { }
  -- Dictinary of all non-train vehicles currently slowing down. Used for regenerative braking.
  -- [unit-number] = braking data
  global.braking_vehicles = { }
  
  -- Passive prototype data
  
  -- Dictionary of recognized transformer equipment
  global.transformers = { }
  -- Dictionary of recognized regenerating brakes equipment
  -- [name] = efficiency
  global.brakes = { }
end

local function on_load()
  rebuild_caches()
end

local function on_configuration_changed(data)
  validate_prototypes()
  validate_entities()
end

script.on_init(on_init)
script.on_load(on_load)
script.on_configuration_changed(on_configuration_changed)

script.on_event(defines.events.on_built_entity, on_built_entity)
script.on_event(defines.events.script_raised_built, script_raised_built)
script.on_event(defines.events.on_entity_died, on_entity_died)
script.on_event(defines.events.on_player_placed_equipment, on_player_placed_equipment)
script.on_event(defines.events.on_player_removed_equipment, on_player_removed_equipment)
script.on_event(defines.events.on_pre_player_mined_item, on_pre_player_mined_item)
script.on_event(defines.events.on_robot_pre_mined, on_robot_pre_mined)
script.on_event(defines.events.on_tick, on_tick)
script.on_event(defines.events.on_train_changed_state, on_train_changed_state)
