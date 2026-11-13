-- Minimal MQTT 3.1.1 client for SmartThings Edge (cosock TCP, no TLS, no auth).
-- Supports: CONNECT, SUBSCRIBE (qos 0/1), PUBLISH in/out (qos 0/1), PUBACK, PINGREQ.
-- One cosock task owns the socket. Other coroutines only append to an outbox table.

local cosock = require "cosock"
local socket = cosock.socket

local M = {}
M.__index = M

local PKT = {
  CONNECT = 1, CONNACK = 2, PUBLISH = 3, PUBACK = 4,
  SUBSCRIBE = 8, SUBACK = 9, PINGREQ = 12, PINGRESP = 13, DISCONNECT = 14,
}

----------------------------------------------------------------------
-- encoding helpers
----------------------------------------------------------------------
local function enc_len(n)
  local out = {}
  repeat
    local b = n % 128
    n = n // 128
    if n > 0 then b = b | 0x80 end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

local function enc_str(s)
  return string.pack(">s2", s)
end

local function packet(first_byte, body)
  return string.char(first_byte) .. enc_len(#body) .. body
end

M._enc_len = enc_len -- exposed for tests

--- Try to cut one packet from the front of buf (test helper; the client reads packets directly).
-- @return first_byte, body, rest  or nil if incomplete
local function decode_one(buf)
  if #buf < 2 then return nil end
  local mult, len, pos = 1, 0, 2
  while true do
    if pos > #buf then return nil end
    local b = buf:byte(pos)
    len = len + (b & 0x7F) * mult
    pos = pos + 1
    if b & 0x80 == 0 then break end
    mult = mult * 128
    if mult > 128 * 128 * 128 then error("malformed remaining length") end
  end
  if #buf < pos - 1 + len then return nil end
  return buf:byte(1), buf:sub(pos, pos - 1 + len), buf:sub(pos + len)
end

M._decode_one = decode_one

----------------------------------------------------------------------
-- client
----------------------------------------------------------------------

--- opts: host, port, client_id, keepalive (s), subscriptions = {{topic, qos}},
---       on_message(topic, payload), on_connect(), on_disconnect(reason), log (table with info/warn/debug)
function M.new(opts)
  local self = setmetatable({}, M)
  self.host = assert(opts.host, "host")
  self.port = opts.port or 1883
  self.client_id = assert(opts.client_id, "client_id")
  self.keepalive = opts.keepalive or 60
  self.subscriptions = opts.subscriptions or {}
  self.on_message = opts.on_message or function() end
  self.on_connect = opts.on_connect or function() end
  self.on_disconnect = opts.on_disconnect or function() end
  self.log = opts.log or { info = print, warn = print, debug = function() end }
  self.outbox = {}
  self.next_id = 1
  self.running = false
  self.connected = false
  return self
end

function M:_packet_id()
  local id = self.next_id
  self.next_id = (id % 65535) + 1
  return id
end

--- Queue a publish. Safe to call from any coroutine.
function M:publish(topic, payload, qos)
  qos = qos or 0
  local body
  if qos > 0 then
    body = enc_str(topic) .. string.pack(">I2", self:_packet_id()) .. payload
  else
    body = enc_str(topic) .. payload
  end
  table.insert(self.outbox, packet(0x30 | (qos << 1), body))
end

--- Re-send SUBSCRIBE; the broker replays retained messages (used for refresh).
function M:resubscribe()
  if self.connected then table.insert(self.outbox, self:_subscribe_packet()) end
end

function M:_subscribe_packet()
  local body = { string.pack(">I2", self:_packet_id()) }
  for _, s in ipairs(self.subscriptions) do
    body[#body + 1] = enc_str(s[1]) .. string.char(s[2] or 0)
  end
  return packet(0x82, table.concat(body))
end

function M:_connect_packet()
  local flags = 0x02 -- clean session, no auth, no will
  local body = enc_str("MQTT") .. string.char(4, flags) .. string.pack(">I2", self.keepalive) .. enc_str(self.client_id)
  return packet(0x10, body)
end

function M:_send(sock, data)
  sock:settimeout(5)
  local i = 1
  while i <= #data do
    local sent, err, last = sock:send(data, i)
    if not sent then
      if err == "timeout" and last and last >= i then
        i = last + 1
      else
        return nil, err
      end
    else
      i = sent + 1
    end
  end
  self.last_tx = os.time()
  return true
end

function M:_handle(sock, first, body)
  local ptype = first >> 4
  if ptype == PKT.PUBLISH then
    local qos = (first >> 1) & 0x03
    local tlen = string.unpack(">I2", body)
    local topic = body:sub(3, 2 + tlen)
    local pos = 3 + tlen
    if qos > 0 then
      local pid = string.unpack(">I2", body, pos)
      pos = pos + 2
      assert(self:_send(sock, packet(0x40, string.pack(">I2", pid))))
    end
    local ok, err = pcall(self.on_message, topic, body:sub(pos))
    if not ok then self.log.warn("mqtt on_message error: " .. tostring(err)) end
  elseif ptype == PKT.CONNACK then
    local rc = body:byte(2)
    if rc ~= 0 then error("CONNACK refused rc=" .. tostring(rc)) end
    return "connack"
  elseif ptype == PKT.SUBACK then
    local codes = {}
    for i = 3, #body do codes[#codes + 1] = string.format("%d", body:byte(i)) end
    self.log.debug("mqtt SUBACK codes=" .. table.concat(codes, ","))
  elseif ptype == PKT.PUBACK or ptype == PKT.PINGRESP then
    -- nothing to do
  else
    self.log.debug(string.format("mqtt ignoring packet type %d", ptype))
  end
end

-- Reading rules (learned the hard way, 2026-11-13):
-- * Never rely on the partial result of a receive that TIMES OUT. cosock handles that
--   path differently by version: 0.2.0 (luarocks) drops earlier chunks, the hub's
--   cosock returned the last chunk twice (every packet was processed twice).
-- * So: wait with select, then read exactly one MQTT packet with blocking receive(n)
--   calls (header byte, length bytes, body). A timeout there is treated as fatal.
-- * select only sees the kernel socket. luasocket may already hold the next packet
--   in its own buffer. sock:dirty() would tell, but the hub's sockets do not have it
--   ("attempt to call a nil value"). Instead probe with a non-blocking 1-byte read:
--   a 1-byte read cannot be partial, so the timeout quirks above cannot bite.

local READ_TIMEOUT = 10

local function read_exact(sock, n)
  if n == 0 then return "" end
  local data, err = sock:receive(n)
  if not data then error("read " .. n .. " bytes: " .. tostring(err), 0) end
  return data
end

--- Non-blocking: return the next byte if one is already available, else nil. Raises if closed.
local function try_byte(sock)
  sock:settimeout(0)
  local b, err = sock:receive(1)
  if b and #b == 1 then return b end
  if err and err ~= "timeout" then error("read: " .. tostring(err), 0) end
  return nil
end

--- Read exactly one packet (blocking, READ_TIMEOUT). `first` = header byte if already read.
-- Raises on error.
function M:_read_packet(sock, first)
  sock:settimeout(READ_TIMEOUT)
  first = (first or read_exact(sock, 1)):byte()
  local mult, len = 1, 0
  repeat
    local b = read_exact(sock, 1):byte()
    len = len + (b & 0x7F) * mult
    mult = mult * 128
    if mult > 128 * 128 * 128 * 128 then error("malformed remaining length", 0) end
  until b & 0x80 == 0
  local body = read_exact(sock, len)
  self.last_rx = os.time()
  return first, body
end

--- Wait up to `wait` seconds for input, then process every packet that is ready.
-- Raises on read errors (callers pcall this).
function M:_pump(sock, wait)
  local pre = try_byte(sock) -- data may already sit in luasocket's buffer
  if not pre then
    local readable = socket.select({ sock }, {}, wait)
    if not readable or #readable == 0 then return true end
  end
  for _ = 1, 50 do
    local first, body = self:_read_packet(sock, pre)
    if self:_handle(sock, first, body) == "connack" then self.got_connack = true end
    pre = try_byte(sock)
    if not pre then break end
  end
  return true
end

function M:_session()
  local sock = assert(socket.tcp())
  sock:settimeout(5)
  local ok, err = sock:connect(self.host, self.port)
  if not ok then sock:close(); return nil, "connect: " .. tostring(err) end
  self.sock = sock
  self.got_connack = false
  self.last_rx = os.time()
  self.outbox = {} -- drop commands queued while offline: they would be stale

  local function fail(e)
    sock:close()
    self.sock = nil
    return nil, e
  end

  local sent, serr = self:_send(sock, self:_connect_packet())
  if not sent then return fail("send CONNECT: " .. tostring(serr)) end
  local deadline = os.time() + 5
  while not self.got_connack do
    local okp, perr = pcall(self._pump, self, sock, 1)
    if not okp then return fail(perr) end
    if os.time() > deadline then return fail("no CONNACK") end
  end
  sent, serr = self:_send(sock, self:_subscribe_packet())
  if not sent then return fail("send SUBSCRIBE: " .. tostring(serr)) end

  self.connected = true
  self.log.info(string.format("mqtt connected to %s:%d as %s", self.host, self.port, self.client_id))
  pcall(self.on_connect)

  while self.running do
    -- flush queued packets
    while #self.outbox > 0 do
      local pkt = table.remove(self.outbox, 1)
      sent, serr = self:_send(sock, pkt)
      if not sent then return fail("send: " .. tostring(serr)) end
    end
    local okp, a, b = pcall(self._pump, self, sock, 0.2)
    if not okp then return fail(a) end
    if not a then return fail(b) end
    local now = os.time()
    if now - (self.last_tx or 0) >= self.keepalive // 2 then
      sent, serr = self:_send(sock, packet(0xC0, ""))
      if not sent then return fail("send PINGREQ: " .. tostring(serr)) end
    end
    if now - self.last_rx > self.keepalive * 3 // 2 then
      return fail("keepalive timeout")
    end
  end

  pcall(self._send, self, sock, packet(0xE0, ""))
  sock:close()
  self.sock = nil
  return true
end

function M:start()
  if self.running then return end
  self.running = true
  cosock.spawn(function()
    local backoff = 2
    while self.running do
      local ok, err = self:_session()
      if self.connected then
        self.connected = false
        pcall(self.on_disconnect, err or "stopped")
        backoff = 2
      end
      if not self.running then break end
      self.log.warn(string.format("mqtt %s:%d disconnected (%s), retry in %ds", self.host, self.port, tostring(err), backoff))
      socket.sleep(backoff)
      backoff = math.min(backoff * 2, 60)
    end
  end, "mqtt-" .. self.client_id)
end

function M:stop()
  self.running = false
end

return M
