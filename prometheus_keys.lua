-- Storage to keep track of used keys. Allows to atomically create, delete
-- and list keys. The keys are synchronized between nginx workers
-- using ngx.shared.dict. The whole purpose of this module is to avoid
-- using ngx.shared.dict:get_keys (see https://github.com/openresty/lua-nginx-module#ngxshareddictget_keys),
-- which blocks all workers and therefore it shouldn't be used with large
-- amounts of keys.

local KeyIndex = {}
KeyIndex.__index = KeyIndex

local lock_lib = require("prometheus_lock")

function KeyIndex.new(shared_dict)
  local self = setmetatable({}, KeyIndex)
  self.dict = shared_dict
  self.keys = {}
  self.index = {}
  self.lock = lock_lib.new("__lock_keys", self.dict)
  return self
end

-- Loads new keys that might have been added by other workers since last sync.
function KeyIndex:sync()
  local N = self.dict:get("__key_count") or 0
  -- Only sync if there are some new keys.
  if N ~= #self.keys then
    for i = #self.keys, N do
      -- Read i-th key. If it is nil, it means it was deleted by some other thread.
      local key = self.dict:get("__key_" .. i)
      if key then
        self.keys[i] = key
        self.index[key] = i
      end
    end
  end
  return N
end

-- Returns list of all keys. Indices might contain "holes" in places where
-- some keys were deleted.
function KeyIndex:get()
  self:sync()
  return self.keys
end

-- Atomically adds one or more keys to the index.
--
-- Args:
--   key_or_keys: Single string or a list of strings containing keys to add.
function KeyIndex:add(key_or_keys)
  local keys = key_or_keys
  if type(key_or_keys) == "string" then
    keys = { key_or_keys }
  end

  -- This must happen atomically, otherwise there could be a race condition
  -- and other workers might create the same records at the same time
  -- with different values.
  if self.lock:wait() then
    local N = self:sync()
    for _, key in pairs(keys) do
      -- Skip keys which already exist in this index or in the shared dict.
      if self.index[key]==nil and self.dict:get(key) == nil then
        N = N + 1
        self.dict:safe_add("__key_" .. N, key)
        self.keys[N] = key
        self.index[key] = N
      end
    end
    self.dict:safe_set("__key_count", N)
  else
    self.log_error("Failed to lock while creating key!")
  end
  self.lock:unlock()
end

-- Removes a key based on its index. This method is slightly more effective
-- than remove_by_key(), but can only be used when the index is known
-- (e.g.: when the user iterates over result from get()).
--
-- Args:
--   i: numeric index of the key
function KeyIndex:remove_by_index(i)
  self.index[self.keys[i]] = nil
  self.keys[i] = nil
  self.dict:safe_set("__key_" .. i, nil)
end

-- Removes a key based on its value.
--
-- Args:
--   key: String value of the key, must exists in this index.
function KeyIndex:remove_by_key(key)
  self:remove_by_index(self.index[key])
end

return KeyIndex
