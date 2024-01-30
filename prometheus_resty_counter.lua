local ngx_shared = ngx.shared
local pairs = pairs
local ngx = ngx
local error = error
local setmetatable = setmetatable
local tonumber = tonumber

local clear_tab
do
  local ok
  ok, clear_tab = pcall(require, "table.clear")
  if not ok then
    clear_tab = function(tab)
      for k in pairs(tab) do
        tab[k] = nil
      end
    end
  end
end

local _M = {
  _VERSION = '0.2.1'
}
local mt = { __index = _M }

-- local cache of counters increments
local increments = {}
-- boolean flags of per worker sync timers
local timer_started = {}

local id

local function sync(_, self)
  local err, _, forcible
  local ok = true
  for k, value in pairs(self.increments) do
    local v = value.v
    _, err, forcible = self.dict:incr(k, v, 0)
    if forcible then
      ngx.log(ngx.ERR, "increasing counter in shdict: lru eviction: key=", k)
      ok = false
    end
    if err then
      ngx.log(ngx.ERR, "error increasing counter in shdict key: ", k, ", err: ", err)
      ok = false
    end
    if value.t then
      self.dict:expire(k, value.t)
    end
  end

  clear_tab(self.increments)
  if ok == false then
    self.dict:incr(self.error_metric_name, 1, 0)
  end

  return ok
end

function _M.new(shdict_name, sync_interval, error_metric_name)
  id = ngx.worker.id()

  if not ngx_shared[shdict_name] then
    error("shared dict \"" .. (shdict_name or "nil") .. "\" not defined", 2)
  end

  if not increments[shdict_name] then
    increments[shdict_name] = {}
  end

  local self = setmetatable({
    dict = ngx_shared[shdict_name],
    increments = increments[shdict_name],
    error_metric_name = error_metric_name,
  }, mt)

  if sync_interval then
    sync_interval = tonumber(sync_interval)
    if not sync_interval or sync_interval < 0 then
      error("expect sync_interval to be a positive number", 2)
    end
    if not timer_started[shdict_name] then
      ngx.log(ngx.DEBUG, "start timer for shdict ", shdict_name, " on worker ", id)
      ngx.timer.every(sync_interval, sync, self)
      timer_started[shdict_name] = true
    end
  end

  return self
end

function _M:sync()
  return sync(false, self)
end

function _M:incr(key, step, exptime)
  step = step or 1
  local value = self.increments[key]
  if value then
    step = step + value.v
  end

  self.increments[key] = {v = step, t = exptime}
  return true
end

function _M:reset(key, number, exptime)
  if not number then
    return nil, "expect a number at #2"
  end
  local newval, err, forcible = self.dict:incr(key, -number, number)
  if exptime then
    self.dict:expire(key, exptime)
  end
  return newval, err, forcible
end

function _M:get(key)
  return self.dict:get(key)
end

function _M:get_keys(max_count)
  return self.dict:get_keys(max_count)
end

return _M
