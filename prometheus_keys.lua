-- Storage to keep track of used keys. Allows to atomically create, delete
-- and list keys. The keys are synchronized between nginx workers
-- using ngx.shared.dict. The whole purpose of this module is to avoid
-- using ngx.shared.dict:get_keys (see https://github.com/openresty/lua-nginx-module#ngxshareddictget_keys),
-- which blocks all workers and therefore it shouldn't be used with large
-- amounts of keys.
--
-- Each key also has a reverse "rkey_<key> -> slot" entry, so add() does not
-- need a synced index. A fresh worker never scans the whole index, which
-- avoids all workers doing that at once (and contending on the dictionary
-- lock) after a reload.

local KeyIndex = {}
KeyIndex.__index = KeyIndex

-- Releases build_reverse()'s lock if its holder dies mid-scan.
local REVERSE_LOCK_TTL = 60

function KeyIndex.new(shared_dict, prefix, delete_callback)
  local self = setmetatable({}, KeyIndex)
  self.dict = shared_dict
  self.key_prefix = prefix .. "key_"
  self.rkey_prefix = prefix .. "rkey_"
  self.rkey_upto = prefix .. "rkey_upto"
  self.rkey_lock = prefix .. "rkey_lock"
  self.delete_count = prefix .. "delete_count"
  self.key_count = prefix .. "key_count"
  self.last = 0
  -- a fresh worker has no local lookups to invalidate for past deletes
  self.deleted = shared_dict:get(self.delete_count) or 0
  self.keys = {}
  self.index = {}
  self.delete_callback = delete_callback
  return self
end

-- Adds missing reverse entries for keys stored by earlier versions of this
-- library, which share the dictionary after a reload. Only scans keys added
-- since the previous call. One worker at a time; others skip it, and a key
-- they add meanwhile may get a duplicate slot, which list() hides.
function KeyIndex:build_reverse()
  if not self.dict:add(self.rkey_lock, true, REVERSE_LOCK_TTL) then
    return
  end
  local N = self.dict:get(self.key_count) or 0
  for i = (self.dict:get(self.rkey_upto) or 0) + 1, N do
    local key = self.dict:get(self.key_prefix .. i)
    if key then
      self.dict:add(self.rkey_prefix .. key, i)
    end
  end
  self.dict:set(self.rkey_upto, N)
  self.dict:delete(self.rkey_lock)
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

-- Cheap periodic check: add() does not need the index to be in sync, only
-- deletes must reach delete_callback.
function KeyIndex:sync_deletes()
  local delete_count = self.dict:get(self.delete_count) or 0
  if self.deleted ~= delete_count then
    self:sync_range(0, self.dict:get(self.key_count) or 0)
    self.deleted = delete_count
  end
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
      self.delete_callback(self.keys[i])
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
  local seen = {}
  local i = 1
  for _, v in pairs(self.keys) do
    -- concurrent add() of one key by two workers can leave a transient duplicate
    if not seen[v] then
      seen[v] = true
      copy[i] = v
      i = i + 1
    end
  end
  return copy
end

-- Allocates a new slot for key and publishes its reverse entry.
function KeyIndex:insert(key, overwrite_rkey, err_msg_lru_eviction)
  local rkey = self.rkey_prefix .. key
  local N = 0
  while true do
    -- step past occupied slots: after flush_all or eviction, key_count can lag
    -- behind them, and re-reading it alone would retry the same slot forever
    N = math.max(N + 1, (self.dict:get(self.key_count) or 0) + 1)
    local ok, err, forcible = self.dict:add(self.key_prefix .. N, key)
    if ok then
      local count, _, forcible2 = self.dict:incr(self.key_count, 1, 0)
      if count and count < N then
        -- only ever raise key_count, so concurrent workers can't lower it
        self.dict:incr(self.key_count, N - count, 0)
      end
      local ok3, err3, forcible3
      if overwrite_rkey then
        ok3, err3, forcible3 = self.dict:set(rkey, N)
      else
        ok3, err3, forcible3 = self.dict:add(rkey, N)
      end
      if not ok3 and err3 == "exists" then
        -- another worker added the same key concurrently; use its slot
        self.dict:delete(self.key_prefix .. N)
        N = self.dict:get(rkey) or N
      elseif not ok3 then
        return "Unexpected error adding a key: " .. err3
      end
      self.keys[N] = key
      self.index[key] = N
      if forcible or forcible2 or forcible3 then
        return (err_msg_lru_eviction .. "; key index: add key: idx=" ..
          self.key_prefix .. N .. ", key=" .. key)
      end
      return
    elseif err ~= "exists" then
      return "Unexpected error adding a key: " .. err
    end
  end
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
    if self.index[key] == nil then
      local i = self.dict:get(self.rkey_prefix .. key)
      if i and self.dict:get(self.key_prefix .. i) == key then
        self.keys[i] = key
        self.index[key] = i
      else
        -- missing, or stale (slot evicted or reused): allocate a new slot
        local err = self:insert(key, i ~= nil, err_msg_lru_eviction)
        if err then
          return err
        end
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
    self.dict:delete(self.rkey_prefix .. key)
    self.deleted = self.deleted + 1

    -- increment delete_count to signal other workers that they should do a full sync
    local _, err, forcible = self.dict:incr(self.delete_count, 1, 0)
    if err or forcible then
      return err or err_msg_lru_eviction
    end
  else
    ngx.log(ngx.ERR, "Trying to remove non-existent key: ", key)
  end
end

return KeyIndex
