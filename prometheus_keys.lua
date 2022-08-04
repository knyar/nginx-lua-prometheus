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

-- Returns array of all keys.
function KeyIndex:list()
  self:sync()
  local copy = {}
  local i = 1
  for _, v in pairs(self.keys) do
    copy[i] = v
    i = i + 1
  end
  return copy
end

-- Atomically adds one or more keys to the index.
--
-- Args:
--   key_or_keys: Single string or a list of strings containing keys to add.
--
-- Returns:
--   nil on success, string with error message otherwise
function KeyIndex:add(key_or_keys, err_msg_lru_eviction)
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
      local ok, err, forcible = self.dict:add(self.key_prefix .. N, key)
      if ok then
        local _, _, forcible2 = self.dict:incr(self.key_count, 1, 0)
        self.keys[N] = key
        self.index[key] = N
        if forcible or forcible2 then
          return (err_msg_lru_eviction .. "; key index: add key: idx=" ..
            self.key_prefix .. N .. ", key=" .. key)
        end
        break
      elseif err ~= "exists" then
        return "Unexpected error adding a key: " .. err
      end
    end
  end
end

-- Removes a key based on its value.
--
-- Args:
--   key: String value of the key, must exists in this index.
function KeyIndex:remove(key, err_msg_lru_eviction)
  local i = self.index[key]
  if i then
    self.index[key] = nil
    self.keys[i] = nil
    self.dict:set(self.key_prefix .. i, nil)
    self.deleted = self.deleted + 1

    -- increment delete_count to signalize other workers that they should do a full sync
    local _, err, forcible = self.dict:incr(self.delete_count, 1, 0)
    if err or forcible then
      return err or err_msg_lru_eviction
    end
  else
    ngx.log(ngx.ERR, "Trying to remove non-existent key: ", key)
  end
end

return KeyIndex
