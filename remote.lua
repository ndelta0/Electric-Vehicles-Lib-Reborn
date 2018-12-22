events =
{
  -- Called when charging of an entity begins.
  -- entity: the entity that is now charging
  -- charging_entityes: array of player-placed entities associated with charging process.
  on_charging_started = script.generate_event_name(),
  -- Called when an entity is no longer being charged because it moved out of range, something was destroyed, etc.
  -- entity: the affected entity
  -- charging_entityes: array of player-placed entities that were associated with the charging process.
  on_charging_stopped = script.generate_event_name(),
}

remote.add_interface("electric-vehicles-lib", {
  --- Register a new equipment type to be recognized as transformer. It should be a "battery-equipment" type and have its "usage_priority" set to "primary-input".
  -- @param data A table containing these values:
  --   name: the name of the equipment prototype
  ["register-transformer"] = register_transformer,
  --- Register a new equipment type to be recognized as regenerative brake. It should be a "battery-equipment" type and have its "usage_priority" set to "primary-output".
  -- @param data A table containing these values:
  --   name: the name of the equipment prototype
  --   efficiency: the efficiency of energy recovery in range [0,1]
  ["register-brake"] = register_brake,
})
