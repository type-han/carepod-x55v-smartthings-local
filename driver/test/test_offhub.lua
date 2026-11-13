-- Off-hub tests for driver/src/mqtt.lua and carepod.lua (Lua 5.3 + cosock + dkjson).
-- Run from driver/:
--   lua5.3 test/test_offhub.lua                                   unit tests only (no network)
--   lua5.3 test/test_offhub.lua --live <broker_ip> <deviceId>     + connects to the broker, reads
--                                                                 retained state, changes mist.step and restores it

package.path = "./src/?.lua;" .. package.path
-- the humidifier does not ack a msgId it has already seen: seed so each run uses new ids
math.randomseed(os.time() + math.floor(os.clock() * 1e6))
local json = require "dkjson"
local carepod = require "carepod"
local mqtt = require "mqtt"

local live, positional = false, {}
for _, a in ipairs(arg) do
  if a == "--live" then live = true else positional[#positional + 1] = a end
end
local broker, live_id = positional[1], carepod.normalize_device_id(positional[2])
if live and (not broker or not live_id) then
  print("usage: lua5.3 test/test_offhub.lua --live <broker_ip> <deviceId>")
  os.exit(2)
end

local FAKE_ID = "A0C6A5000001" -- example id for unit tests (not a real device)

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name) else fails = fails + 1; print("  FAIL " .. name .. (extra and (" : " .. extra) or "")) end
end

print("== unit")
for _, n in ipairs({ 0, 1, 127, 128, 16383, 16384, 2097151 }) do
  local enc = mqtt._enc_len(n)
  local first, body, rest = mqtt._decode_one("\x30" .. enc .. string.rep("x", n) .. "TAIL")
  check("remaining length " .. n, first == 0x30 and #body == n and rest == "TAIL")
end
check("incomplete packet", mqtt._decode_one("\x30\x05abc") == nil)

local state = json.decode([[{"ts":1,"msgId":"m","deviceId":"A0C6A5000001","fw_wifi":"0.0.1","type":"state","payload":{"model":"x55v","fw_mcu":"1.0.4","power":1,"wifi":{"connected":1,"rssi":-50,"reset":0},"mist":{"step":3,"target_humidity":55},"heat":{"state":0,"target_x10":490,"current_x10":478},"sterilize":{"state":1,"remain":0},"fan":{"step":3,"state":1},"drain":{"active":0,"remain":0},"timer":{"active":0,"remain":0},"sleep":{"active":0},"child_lock":{"active":1},"errors":"","warning":"0","ota_active":0}}]])
local got = {}
for _, u in ipairs(carepod.decode("x/state", state)) do got[u.component .. "." .. u.kind] = u.value end
check("state power", got["main.switch"] == "on")
check("state mist mode", got["mist.mode"] == "3단계", tostring(got["mist.mode"]))
check("state target", got["humidityTarget.mode"] == "55%", tostring(got["humidityTarget.mode"]))
check("state heat", got["heat.switch"] == "off")
check("state sterilize", got["sterilize.switch"] == "on")
check("state sleep", got["sleep.switch"] == "off")
check("state child lock", got["childLock.switch"] == "on")
local alert = nil
for _, u in ipairs(carepod.decode("x/state", state)) do if u.kind == "alert" then alert = u end end
check("state alert normal", alert and alert.value == "normal" and alert.code == "-", alert and (alert.value .. " " .. alert.code))

local function alert_of(e, w) local s, c = carepod.alert_of(e, w); return s .. "|" .. c end
check("alert: '' / '0' -> normal", alert_of("", "0") == "normal|-")
check("alert: nil / 0 (number) -> normal", alert_of(nil, 0) == "normal|-")
check("alert: JSON null -> normal", alert_of(json.null, json.null) == "normal|-")
check("alert: warning 2 -> warning", alert_of("", "2") == "warning|W:2")
check("alert: errors E1 -> error", alert_of("E1", "0") == "error|E:E1")
check("alert: both -> error, both codes", alert_of("E1", "3") == "error|E:E1 W:3")
check("alert: code capped at 64 chars", #select(2, carepod.alert_of(string.rep("x", 100), "0")) == 64)

local tel = carepod.decode("x/telemetry", json.decode([[{"type":"telemetry","payload":{"temp_x10":285,"humidity":48,"water_level":3}}]]))
check("telemetry", tel[1].kind == "humidity" and tel[1].value == 48 and tel[2].value == 28.5)
check("telemetry water level", tel[3] and tel[3].kind == "water" and tel[3].value == 3)
local tw = carepod.decode("x", { type = "telemetry", payload = { water_level = 7 } })
check("water level clamped to 3", tw[1].value == 3)
check("presence", carepod.decode("x", { type = "presence", payload = { status = "online" } })[1].value == "online")

local function mist_of(step)
  local r = carepod.decode("x", { type = "state", payload = { mist = { step = step } } })
  return r[1] and r[1].value
end
check("step 5 -> 자동", mist_of(5) == "자동")
check("step 4 -> 취침 (read-only)", mist_of(4) == "취침")
check("step 0 -> no mode event", mist_of(0) == nil)

check("mode 1단계 -> 1", carepod.mist_mode_to_step("1단계") == 1)
check("mode 3단계 -> 3", carepod.mist_mode_to_step("3단계") == 3)
check("mode 자동 -> 5", carepod.mist_mode_to_step("자동") == 5)
check("mode 취침 not settable", carepod.mist_mode_to_step("취침") == nil)
check("unknown mode -> nil", carepod.mist_mode_to_step("4단계") == nil)
check("target 45% -> 45", carepod.target_mode_to_value("45%") == 45)
check("target 60 -> 60", carepod.target_mode_to_value("60") == 60)
check("target 52% rejected", carepod.target_mode_to_value("52%") == nil)
check("target 65% rejected", carepod.target_mode_to_value("65%") == nil)
check("target 35% rejected", carepod.target_mode_to_value("35%") == nil)

for _, bad in ipairs({ { "mist.step", 0 }, { "mist.step", 4 }, { "mist.step", 6 },
                       { "mist.target_humidity", 52 }, { "mist.target_humidity", 65 }, { "mist.target_humidity", 30 } }) do
  check("unsafe refused: " .. bad[1] .. "=" .. bad[2], carepod.make_cmd(json, "X", bad[1], bad[2]) == nil)
end
check("safe accepted: mist.step=5", carepod.make_cmd(json, "X", "mist.step", 5) ~= nil)
check("power 0 still allowed", carepod.make_cmd(json, "X", "power", 0) ~= nil)

check("deviceId with colons", carepod.normalize_device_id("a0:c6:a5:00:00:01") == FAKE_ID)
check("deviceId with dashes and spaces", carepod.normalize_device_id(" A0-C6-A5-00-00-01 ") == FAKE_ID)
check("deviceId plain lower case", carepod.normalize_device_id("a0c6a5000001") == FAKE_ID)
check("deviceId too short rejected", carepod.normalize_device_id("A0C6A5") == nil)
check("deviceId non-hex rejected", carepod.normalize_device_id("A0C6A50000ZZ") == nil)
check("deviceId empty / nil rejected", carepod.normalize_device_id("") == nil and carepod.normalize_device_id(nil) == nil)
check("trim", carepod.trim("  192.168.1.50 ") == "192.168.1.50" and carepod.trim("   ") == nil)

local cmd, mid = carepod.make_cmd(json, FAKE_ID, "mist.step", 3, 100)
local c = json.decode(cmd)
check("cmd json", c.type == "cmd" and c.payload.path == "mist.step" and c.payload.value == 3 and c.msgId == mid and c.ts == 100)
check("uuid4 format", mid:match("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$") ~= nil, mid)
check("cmd key order", cmd == '{"ts":100,"msgId":"' .. mid .. '","deviceId":"A0C6A5000001","fw_wifi":"0.0.1","type":"cmd","payload":{"op":"set","path":"mist.step","value":3}}', cmd)
local cmdf = carepod.make_cmd(json, FAKE_ID, "mist.target_humidity", 55.0, 100)
check("float value encoded as integer", cmdf:find('"value":55}', 1, true) ~= nil, cmdf)
local rs = json.decode((carepod.make_restore(json, FAKE_ID, 1794569662)))
check("restore value", rs.payload.path == "restore" and rs.payload.value.country == "KR" and rs.payload.value.utc_offset_min == 540 and rs.payload.value.now == 1794569662)
check("restore key order", (carepod.make_restore(json, "X", 5)):find('"value":{"country":"KR","utc_offset_min":540,"now":5}}}', 1, true) ~= nil)

if not live then
  print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
  os.exit(fails == 0 and 0 or 1)
end

----------------------------------------------------------------------
print("== live against " .. broker .. ":1883, deviceId " .. live_id)
local cosock = require "cosock"
local ID = live_id
local T = carepod.topics(ID)

local last = {}        -- component.kind -> value
local acks = {}        -- msg_id -> status
-- The firmware sometimes acks with the PREVIOUS command's msgId (one behind) after it
-- received a command it could not handle; commands still apply at once. So the test
-- only requires that some ack arrives after each command.
local ack_count = 0
local presence = nil
local connected = false
local seen, dups = {}, 0 -- every message must be delivered exactly once

local client = mqtt.new({
  host = broker, port = 1883, client_id = "carepod-offhub-test", keepalive = 30,
  subscriptions = carepod.subscriptions(ID),
  log = { info = print, warn = print, debug = function() end },
  on_connect = function() connected = true end,
  on_message = function(topic, payload)
    local m = json.decode(payload)
    if m and m.msgId then
      if seen[m.msgId] then dups = dups + 1 end
      seen[m.msgId] = true
    end
    for _, u in ipairs(carepod.decode(topic, m)) do
      if u.kind == "ack" then acks[u.msg_id] = u.status; ack_count = ack_count + 1
      elseif u.kind == "presence" then presence = u.value
      else last[(u.component or "main") .. "." .. u.kind] = u.value end
    end
  end,
})

local function wait_for(cond, secs)
  local t0 = os.time()
  while not cond() do
    if os.time() - t0 > secs then return false end
    cosock.socket.sleep(0.1)
  end
  return true
end

cosock.spawn(function()
  client:start()
  check("connected", wait_for(function() return connected end, 10))
  check("retained presence online", wait_for(function() return presence == "online" end, 5), tostring(presence))
  check("retained state", wait_for(function() return last["main.switch"] ~= nil end, 5))
  local orig = last["mist.mode"]
  print("  current: power=" .. tostring(last["main.switch"]) .. " mist=" .. tostring(orig) .. " target=" .. tostring(last["humidityTarget.mode"]))

  local orig_step = orig and carepod.mist_mode_to_step(orig)
  if last["main.switch"] == "on" and orig_step then
    -- only safe values: 1/2/3/auto(5). Never 0 or 4.
    local new_step = (orig_step == 3) and 2 or 3
    local new_mode = carepod.mist_step_to_mode(new_step)
    local msg, id1 = carepod.make_cmd(json, ID, "mist.step", new_step)
    local a0 = ack_count
    client:publish(T.cmd, msg, 1)
    check("an ack after mist.step " .. new_step, wait_for(function() return ack_count > a0 end, 5))
    if not acks[id1] then print("  note: ack msgId lags behind (firmware quirk)") end
    check("state mist -> " .. new_mode, wait_for(function() return last["mist.mode"] == new_mode end, 5), tostring(last["mist.mode"]))

    cosock.socket.sleep(1.5) -- leave the firmware a moment between commands
    local msg2, id2 = carepod.make_cmd(json, ID, "mist.step", orig_step)
    local a1 = ack_count
    client:publish(T.cmd, msg2, 1)
    check("an ack after restore step " .. orig_step, wait_for(function() return ack_count > a1 end, 5))
    check("state mist back to " .. orig, wait_for(function() return last["mist.mode"] == orig end, 5), tostring(last["mist.mode"]))
  else
    print("  humidifier is off or in sleep mode: skipping command test")
  end

  check("no message delivered twice", dups == 0, dups .. " duplicates")

  -- refresh = resubscribe -> retained state replayed (same msgIds again, on purpose)
  last["main.switch"] = nil
  client:resubscribe()
  check("resubscribe replays retained state", wait_for(function() return last["main.switch"] ~= nil end, 5))

  client:stop()
  cosock.socket.sleep(0.5)
  print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
  os.exit(fails == 0 and 0 or 1)
end, "test")

cosock.run()
