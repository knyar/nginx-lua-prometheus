-- Storage to keep track of used keys. Allows to atomically create, delete
-- and list keys. The keys are synchronized between nginx workers
-- using ngx.shared.dict. The whole purpose of this module is to avoid
-- using ngx.shared.dict:get_keys (see https://github.com/openresty/lua-nginx-module#ngxshareddictget_keys),
-- which blocks all workers and therefore it shouldn't be used with large
-- amounts of keys.

local KeyIndex = {}
KeyIndex.__index = KeyIndex

function KeyIndex.new(shared_dict, prefix)
  local self = setmetatable({}, KeyIndex)
  self.dict = shared_dict
  self.key_prefix = prefix .. "key_"
  self.delete_count = prefix .. "delete_count"
  self.key_count = prefix .. "key_count"
  self.last = 0
  self.deleted = 0
  self.keys = {}
  self.index = {}
  return self
end

-- Loads new keys that might have been added by other workers since last sync.
function KeyIndex:sync()
  local delete_count = self.dict:get(self.delete_count) or 0
  local N = self.dict:get(self.key_count) or 0
  if self.deleted ~= delete_count then
    -- Some other worker deleted something, lets do a full sync.
    self:sync_range(0, N)
    self.deleted = delete_count
  elseif N ~= self.last then
    -- Sync only new keys, if there are any.
    self:sync_range(self.last, N)
  end
  return N
end

-- Iterates keys from first to last, adds new items and removes deleted items.
function KeyIndex:sync_range(first, last)
  for i = first, last do
    -- Read i-th key. If it is nil, it means it was deleted by some other thread.
    local key = self.dict:get(self.key_prefix .. i)
    if key then
      self.keys[i] = key
      self.index[key] = i
    elseif self.keys[i] then
      self.index[self.keys[i]] = nil
      self.keys[i] = nil
    end
  end
  self.last = last
end

-- Returns list of all keys. Indices might contain "holes" in places where
-- some keys were deleted.
function KeyIndex:list()
  self:sync()
  return self.keys
end

-- Atomically adds one or more keys to the index.
--
-- Args:
--   key_or_keys: Single string or a list of strings containing keys to add.
--
-- Returns:
--   nil on success, string with error message otherwise
function KeyIndex:add(key_or_keys)
  local keys = key_or_keys
  if type(key_or_keys) == "string" then
    keys = { key_or_keys }
  end

  for _, key in pairs(keys) do
    while true do
      local N = self:sync()
      if self.index[key] ~= nil then
        -- key already exists, we can skip it
        break
      end
      N = N+1
      local ok, err = self.dict:safe_add(self.key_prefix .. N, key)
      if ok then
        self.dict:incr(self.key_count, 1, 0)
        self.keys[N] = key
        self.index[key] = N
        break
      elseif err ~= "exists" then
        return "Unexpected error adding a key: " .. err
      end
    end
  end
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
  self.dict:safe_set(self.key_prefix .. i, nil)
  -- increment delete_count to signalize other workers that they should do a full sync
  self.dict:incr(self.delete_count, 1, 0)
  self.deleted = self.deleted + 1
end

-- Removes a key based on its value.
--
-- Args:
--   key: String value of the key, must exists in this index.
function KeyIndex:remove_by_key(key)
  self:remove_by_index(self.index[key])
end

return KeyIndex
