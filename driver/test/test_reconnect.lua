-- Reconnect test: run this, then restart mosquitto on the broker within 15 s.
--   lua5.3 test/test_reconnect.lua <broker_ip> <deviceId>
package.path = "./src/?.lua;" .. package.path
math.randomseed(os.time() + math.floor(os.clock() * 1e6))
local carepod = require "carepod"
local mqtt = require "mqtt"
local cosock = require "cosock"

local broker, device_id = arg[1], carepod.normalize_device_id(arg[2])
if not broker or not device_id then
  print("usage: lua5.3 test/test_reconnect.lua <broker_ip> <deviceId>")
  os.exit(2)
end

local connects, disconnects, states = 0, 0, 0
local c = mqtt.new({
  host = broker, client_id = "carepod-reconnect-test", keepalive = 30,
  subscriptions = carepod.subscriptions(device_id),
  log = { info = print, warn = print, debug = function() end },
  on_connect = function() connects = connects + 1 end,
  on_disconnect = function(r) disconnects = disconnects + 1; print("  disconnected: " .. tostring(r)) end,
  on_message = function(topic) if topic:match("/state$") then states = states + 1 end end,
})

cosock.spawn(function()
  c:start()
  local t0 = os.time()
  while os.time() - t0 < 40 and connects < 2 do cosock.socket.sleep(0.2) end
  local before = states
  cosock.socket.sleep(3)
  print(string.format("connects=%d disconnects=%d states=%d (after reconnect +%d)", connects, disconnects, states, states - before))
  local ok = connects >= 2 and disconnects >= 1 and states > 0
  print(ok and "RECONNECT OK" or "RECONNECT FAILED")
  c:stop()
  cosock.socket.sleep(0.5)
  os.exit(ok and 0 or 1)
end)
cosock.run()
