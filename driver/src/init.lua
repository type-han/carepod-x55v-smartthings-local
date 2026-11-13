-- SmartThings Edge driver: CAREPOD X55V humidifier over a local MQTT broker.
-- The humidifier's cloud MQTT (tcp/1883) must be redirected to a LAN Mosquitto first.
-- See ../../docs/01_LOCAL_BROKER.md

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local mqtt = require "mqtt"
local carepod = require "carepod"

local okj, json = pcall(require, "st.json")
if not okj then json = require "dkjson" end

local DNI = "carepod-x55v-1"
local PROFILE = "carepod-x55v.v3"
-- namespace of the custom capabilities (definitions in driver/capabilities/)
local NS = "fieldforgotten06843"
local WATER_CAP_ID = NS .. ".waterLevel"
local ALERT_CAP_ID = NS .. ".deviceAlert"
local RESTORE_COOLDOWN = 30   -- seconds
local POWER_ON_DELAY = 1.5    -- seconds between "power on" and the next command

local okw, water_cap = pcall(function() return capabilities[WATER_CAP_ID] end)
if not okw then
  log.warn("waterLevel capability unavailable: " .. tostring(water_cap))
  water_cap = nil
end
local oka, alert_cap = pcall(function() return capabilities[ALERT_CAP_ID] end)
if not oka then
  log.warn("deviceAlert capability unavailable: " .. tostring(alert_cap))
  alert_cap = nil
end

local clients = {} -- device.id -> { client = mqtt client, device_id = "...", last_restore = epoch }

math.randomseed(os.time())

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------
local function emit(device, comp_id, event)
  local comp = device.profile.components[comp_id]
  if comp then device:emit_component_event(comp, event) end
end

--- true when the device already runs the current profile (v3: main has deviceAlert)
local function has_current_profile(device)
  local main = device.profile.components["main"]
  if not main or not device.profile.components["mist"] then return false end
  for _, cap in pairs(main.capabilities or {}) do
    if cap.id == ALERT_CAP_ID then return true end
  end
  return false
end

local function emit_supported_modes(device)
  local hidden = { visibility = { displayed = false } }
  local args_attr = capabilities.mode.supportedArguments -- may be missing in older hub libs
  for comp, list in pairs({ mist = carepod.MIST_MODES, humidityTarget = carepod.TARGET_MODES }) do
    emit(device, comp, capabilities.mode.supportedModes(list, hidden))
    if args_attr then emit(device, comp, args_attr(list, hidden)) end
  end
end

local function send_cmd(device, path, value)
  local c = clients[device.id]
  if not c then
    log.warn("no MQTT client for " .. device.label)
    return
  end
  local msg, err = carepod.make_cmd(json, c.device_id, path, value)
  if not msg then
    log.error(string.format("refusing cmd %s = %s (%s)", path, tostring(value), tostring(err)))
    return
  end
  log.info(string.format("cmd %s = %s", path, json.encode(value)))
  c.client:publish(carepod.topics(c.device_id).cmd, msg, 1)
end

local function send_restore(device)
  local c = clients[device.id]
  if not c then return end
  local now = os.time()
  if c.last_restore and now - c.last_restore < RESTORE_COOLDOWN then return end
  c.last_restore = now
  log.info("sending restore (clock / country) to humidifier")
  c.client:publish(carepod.topics(c.device_id).cmd, (carepod.make_restore(json, c.device_id, now)), 1)
end

local function is_on(device)
  return device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) == "on"
end

--- Run fn now if the humidifier is on, else power it on first and run fn a bit later.
local function with_power_on(device, fn)
  if is_on(device) then
    fn()
  else
    send_cmd(device, "power", 1)
    device.thread:call_with_delay(POWER_ON_DELAY, fn)
  end
end

----------------------------------------------------------------------
-- events from the humidifier
----------------------------------------------------------------------
local function apply_update(device, u)
  if u.kind == "switch" then
    emit(device, u.component, u.value == "on" and capabilities.switch.switch.on() or capabilities.switch.switch.off())
  elseif u.kind == "mode" then
    emit(device, u.component, capabilities.mode.mode(u.value))
  elseif u.kind == "humidity" then
    emit(device, "main", capabilities.relativeHumidityMeasurement.humidity(u.value))
  elseif u.kind == "temperature" then
    emit(device, "main", capabilities.temperatureMeasurement.temperature({ value = u.value, unit = "C" }))
  elseif u.kind == "water" then
    if water_cap then emit(device, "main", water_cap.waterLevel(u.value)) end
  elseif u.kind == "alert" then
    if alert_cap then
      local prev = device:get_latest_state("main", ALERT_CAP_ID, "alertStatus")
      if prev ~= u.value then
        local logf = (u.value == "normal") and log.info or log.warn
        logf(string.format("humidifier alert: %s (%s)", u.value, u.code))
      end
      emit(device, "main", alert_cap.alertStatus(u.value))
      emit(device, "main", alert_cap.alertCode(u.code))
    end
  elseif u.kind == "presence" then
    if u.value == "online" then
      device:online()
      send_restore(device)
    else
      log.warn("humidifier reports offline")
      device:offline()
    end
  elseif u.kind == "ack" then
    if u.status ~= "ok" then log.warn(string.format("cmd %s rejected: %s", tostring(u.msg_id), tostring(u.status))) end
  end
end

----------------------------------------------------------------------
-- MQTT client per device
----------------------------------------------------------------------
local function stop_client(device)
  local c = clients[device.id]
  if c then
    c.client:stop()
    clients[device.id] = nil
  end
end

local function start_client(device)
  stop_client(device)
  local prefs = device.preferences or {}
  local host = carepod.trim(prefs.brokerIp)
  local port = tonumber(prefs.brokerPort) or 1883
  local device_id = carepod.normalize_device_id(prefs.deviceId)
  if not host or not device_id then
    log.warn("broker IP or deviceId is not set: open the device settings in the SmartThings app and enter both")
    device:offline()
    return
  end
  log.info(string.format("broker %s:%d, deviceId %s", host, port, device_id))

  local client = mqtt.new({
    host = host,
    port = port,
    -- must differ from the humidifier's own client id, or the broker kicks it off
    client_id = "st-carepod-" .. device.id:sub(1, 8),
    keepalive = 60,
    subscriptions = carepod.subscriptions(device_id),
    log = { info = log.info, warn = log.warn, debug = log.debug },
    on_message = function(topic, payload)
      local msg = json.decode(payload)
      for _, u in ipairs(carepod.decode(topic, msg)) do apply_update(device, u) end
    end,
    on_connect = function() log.info("broker connected; waiting for retained state") end,
    on_disconnect = function(reason)
      log.warn("broker disconnected: " .. tostring(reason))
      device:offline()
    end,
  })
  clients[device.id] = { client = client, device_id = device_id }
  client:start()
end

----------------------------------------------------------------------
-- capability handlers
----------------------------------------------------------------------
local function switch_handler(value)
  return function(_, device, command)
    local path = carepod.SWITCH_PATHS[command.component]
    if path then send_cmd(device, path, value) end
  end
end

local function set_mode(_, device, command)
  local mode = command.args.mode
  if command.component == "mist" then
    local step = carepod.mist_mode_to_step(mode)
    if not step then
      log.warn("ignoring unsupported mist mode: " .. tostring(mode))
      return
    end
    with_power_on(device, function() send_cmd(device, "mist.step", step) end)
  elseif command.component == "humidityTarget" then
    local v = carepod.target_mode_to_value(mode)
    if not v then
      log.warn("ignoring unsupported target humidity: " .. tostring(mode))
      return
    end
    send_cmd(device, "mist.target_humidity", v)
  end
end

local function refresh(_, device)
  local c = clients[device.id]
  if c then c.client:resubscribe() end
end

----------------------------------------------------------------------
-- lifecycle
----------------------------------------------------------------------
local function device_init(_, device)
  log.info("init " .. device.label)
  if has_current_profile(device) then
    device:set_field("profile_ready", true)
  else
    log.info("switching device to profile " .. PROFILE)
    device:try_update_metadata({ profile = PROFILE })
  end
  emit_supported_modes(device)
  device:offline() -- until the humidifier's presence says online
  start_client(device)
end

local function device_info_changed(_, device, _, args)
  local old_st = args and args.old_st_store or {}
  local old_prefs = old_st.preferences or {}
  local new_prefs = device.preferences or {}
  if old_prefs.brokerIp ~= new_prefs.brokerIp or old_prefs.brokerPort ~= new_prefs.brokerPort
      or old_prefs.deviceId ~= new_prefs.deviceId then
    log.info("preferences changed; reconnecting")
    start_client(device)
    return
  end
  -- profile just switched: new components/capabilities exist now, fill them in once
  if has_current_profile(device) and not device:get_field("profile_ready") then
    device:set_field("profile_ready", true)
    log.info("profile is now " .. PROFILE .. "; refreshing state")
    emit_supported_modes(device)
    refresh(nil, device)
  end
end

local function device_removed(_, device)
  stop_client(device)
end

local function discovery(driver, _, _)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == DNI then
      log.info("discovery: device already exists")
      return
    end
  end
  log.info("discovery: creating CAREPOD X55V device")
  driver:try_create_device({
    type = "LAN",
    device_network_id = DNI,
    label = "CAREPOD 가습기",
    profile = PROFILE,
    manufacturer = "HnB",
    model = "X55V",
    vendor_provided_label = "CAREPOD X55V",
  })
end

local driver = Driver("carepod-x55v-local", {
  discovery = discovery,
  lifecycle_handlers = {
    init = device_init,
    infoChanged = device_info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_handler(1),
      [capabilities.switch.commands.off.NAME] = switch_handler(0),
    },
    [capabilities.mode.ID] = {
      [capabilities.mode.commands.setMode.NAME] = set_mode,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
  },
})

driver:run()
