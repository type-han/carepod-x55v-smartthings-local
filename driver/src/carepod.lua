-- CAREPOD X55V protocol mapping (no SmartThings dependencies, testable off-hub).
-- Protocol notes: captures/PROTOCOL.md

local M = {}

-- mist.step values (user-verified 2026-11-13):
--   1, 2, 3 = manual levels, 5 = auto.
--   0 and 4 must NEVER be sent: 0 switched the humidifier off and left the power button
--   misbehaving, 4 switched it off and froze it. Sleep mode sets step 4 by itself (read-only).
M.MIST_MODES = { "1단계", "2단계", "3단계", "자동" }
local MIST_MODE_TO_STEP = { ["1단계"] = 1, ["2단계"] = 2, ["3단계"] = 3, ["자동"] = 5 }
local MIST_STEP_TO_MODE = { [1] = "1단계", [2] = "2단계", [3] = "3단계", [4] = "취침", [5] = "자동" }

-- mist.target_humidity: only 40, 45, 50, 55, 60 are safe (other values broke the humidifier)
M.TARGET_MODES = { "40%", "45%", "50%", "55%", "60%" }
local TARGET_ALLOWED = { [40] = true, [45] = true, [50] = true, [55] = true, [60] = true }

M.WATER_LEVEL_MAX = 3 -- telemetry.water_level is 0..3

-- component -> state path for on/off switches
M.SWITCH_PATHS = {
  main = "power",
  heat = "heat.state",
  sterilize = "sterilize.state",
  sleep = "sleep.active",
  childLock = "child_lock.active",
}

--- trimmed string, or nil when empty / not a string
function M.trim(s)
  if type(s) ~= "string" then return nil end
  s = s:match("^%s*(.-)%s*$")
  if s == "" then return nil end
  return s
end

--- deviceId = humidifier MAC, upper case, no separators.
-- Accepts "a0:c6:a5:12:34:56", "A0-C6-...", "a0c6a5123456". Returns nil unless 12 hex digits.
function M.normalize_device_id(s)
  s = M.trim(s)
  if not s then return nil end
  s = s:gsub("[%s:%-%.]", ""):upper()
  if not s:match("^%x%x%x%x%x%x%x%x%x%x%x%x$") then return nil end
  return s
end

function M.topics(device_id)
  local base = "v1/HNB/" .. device_id
  return {
    base = base,
    state = base .. "/state",
    telemetry = base .. "/telemetry",
    presence = base .. "/presence",
    cmd = base .. "/cmd",
    ack = base .. "/cmd/ack",
  }
end

function M.subscriptions(device_id)
  local t = M.topics(device_id)
  return { { t.state, 0 }, { t.telemetry, 0 }, { t.presence, 0 }, { t.ack, 0 } }
end

local function uuid4()
  local b = {}
  for i = 1, 16 do b[i] = math.random(0, 255) end
  b[7] = (b[7] & 0x0F) | 0x40
  b[9] = (b[9] & 0x3F) | 0x80
  return string.format("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", table.unpack(b))
end

-- The firmware parses commands by KEY ORDER (verified 2026-11-13: a cmd with keys in
-- random order was ignored, no ack). Always emit keys in the cloud's order:
--   ts, msgId, deviceId, fw_wifi, type, payload{op, path, value}
-- so JSON is assembled by hand here instead of json.encode(table).

local function int_or(v)
  if math.type(v) == "float" and v == math.floor(v) then return math.tointeger(v) end
  return v
end

local function enc_scalar(json, v)
  v = int_or(v)
  if math.type(v) == "integer" then return string.format("%d", v) end
  return json.encode(v)
end

--- value may be a scalar, or a raw JSON string wrapped as { raw = "..." }
local function enc_value(json, v)
  if type(v) == "table" and v.raw then return v.raw end
  return enc_scalar(json, v)
end

--- Last line of defence against values that broke the humidifier.
function M.is_safe(path, value)
  if path == "mist.step" then return value == 1 or value == 2 or value == 3 or value == 5 end
  if path == "mist.target_humidity" then return TARGET_ALLOWED[value] == true end
  return true
end

--- Build a cmd message (JSON string) with fixed key order.
-- Returns nil, "unsafe" for values listed in is_safe.
function M.make_cmd(json, device_id, path, value, now)
  value = int_or(value)
  if not M.is_safe(path, value) then return nil, "unsafe" end
  now = int_or(now or os.time())
  local msg_id = uuid4()
  local s = string.format(
    '{"ts":%d,"msgId":%s,"deviceId":%s,"fw_wifi":"0.0.1","type":"cmd","payload":{"op":"set","path":%s,"value":%s}}',
    now, json.encode(msg_id), json.encode(device_id), json.encode(path), enc_value(json, value))
  return s, msg_id
end

--- What the cloud sends right after the humidifier connects (country, timezone, clock).
function M.make_restore(json, device_id, now)
  now = int_or(now or os.time())
  local v = string.format('{"country":"KR","utc_offset_min":540,"now":%d}', now)
  return M.make_cmd(json, device_id, "restore", { raw = v }, now)
end

--- "1단계" / "2단계" / "3단계" / "자동" -> 1/2/3/5. Anything else -> nil (never 0 or 4).
function M.mist_mode_to_step(mode)
  return MIST_MODE_TO_STEP[mode]
end

--- state mist.step -> mode string, or nil for 0 (off: keep the last mode)
function M.mist_step_to_mode(step)
  return MIST_STEP_TO_MODE[step]
end

--- "45%" (or "45") -> 45 if allowed, else nil
function M.target_mode_to_value(mode)
  local n = tonumber(tostring(mode):match("^(%d+)%%?$") or "")
  if n and TARGET_ALLOWED[n] then return math.tointeger(n) end
  return nil
end

function M.target_value_to_mode(v)
  return string.format("%d%%", math.tointeger(v) or math.floor(v))
end

local function onoff(v) return (v == 1 or v == true) and "on" or "off" end

local function blank(v)
  if v == nil or type(v) == "table" then return true end -- table = JSON null sentinel
  local s = tostring(v)
  return s == "" or s == "0"
end

--- state.errors ("" when fine) and state.warning ("0" when fine) -> status, code text.
-- The meaning of individual codes is not known yet; the raw values are shown as-is.
function M.alert_of(errors, warning)
  local parts = {}
  if not blank(errors) then parts[#parts + 1] = "E:" .. tostring(errors) end
  if not blank(warning) then parts[#parts + 1] = "W:" .. tostring(warning) end
  local status = "normal"
  if not blank(errors) then status = "error" elseif not blank(warning) then status = "warning" end
  local code = #parts > 0 and table.concat(parts, " ") or "-"
  if #code > 64 then code = code:sub(1, 64) end
  return status, code
end

--- Turn a decoded message into a list of updates:
---   { kind = "switch",      component = "...", value = "on"|"off" }
---   { kind = "mode",        component = "mist"|"humidityTarget", value = "..." }
---   { kind = "humidity",    value = % }
---   { kind = "temperature", value = celsius }
---   { kind = "water",       value = 0..3 }
---   { kind = "alert",       value = "normal"|"warning"|"error", code = "-"|"E:..."|"W:..." }
---   { kind = "presence",    value = "online"|"offline" }
---   { kind = "ack",         msg_id = "...", status = "ok"|... }
function M.decode(topic, msg)
  local out = {}
  if type(msg) ~= "table" then return out end
  local p = msg.payload
  if type(p) ~= "table" then return out end
  local mtype = msg.type

  if mtype == "state" then
    if p.power ~= nil then out[#out + 1] = { kind = "switch", component = "main", value = onoff(p.power) } end
    if type(p.mist) == "table" then
      local mode = p.mist.step ~= nil and M.mist_step_to_mode(p.mist.step)
      if mode then out[#out + 1] = { kind = "mode", component = "mist", value = mode } end
      if p.mist.target_humidity ~= nil then
        out[#out + 1] = { kind = "mode", component = "humidityTarget", value = M.target_value_to_mode(p.mist.target_humidity) }
      end
    end
    if type(p.heat) == "table" and p.heat.state ~= nil then
      out[#out + 1] = { kind = "switch", component = "heat", value = onoff(p.heat.state) }
    end
    if type(p.sterilize) == "table" and p.sterilize.state ~= nil then
      out[#out + 1] = { kind = "switch", component = "sterilize", value = onoff(p.sterilize.state) }
    end
    if type(p.sleep) == "table" and p.sleep.active ~= nil then
      out[#out + 1] = { kind = "switch", component = "sleep", value = onoff(p.sleep.active) }
    end
    if type(p.child_lock) == "table" and p.child_lock.active ~= nil then
      out[#out + 1] = { kind = "switch", component = "childLock", value = onoff(p.child_lock.active) }
    end
    if p.errors ~= nil or p.warning ~= nil then
      local status, code = M.alert_of(p.errors, p.warning)
      out[#out + 1] = { kind = "alert", component = "main", value = status, code = code }
    end
  elseif mtype == "telemetry" then
    if p.humidity ~= nil then out[#out + 1] = { kind = "humidity", value = p.humidity } end
    if p.temp_x10 ~= nil then out[#out + 1] = { kind = "temperature", value = p.temp_x10 / 10 } end
    if type(p.water_level) == "number" then
      local w = math.tointeger(p.water_level) or math.floor(p.water_level)
      if w < 0 then w = 0 end
      if w > M.WATER_LEVEL_MAX then w = M.WATER_LEVEL_MAX end
      out[#out + 1] = { kind = "water", value = w }
    end
  elseif mtype == "presence" then
    out[#out + 1] = { kind = "presence", value = (p.status == "online") and "online" or "offline" }
  elseif mtype == "ack" then
    out[#out + 1] = { kind = "ack", msg_id = msg.msgId, status = p.status }
  end
  return out
end

return M
