-- Simple class implementing mutex based on ngx.shared.dict:safe_add

local Lock = {}
Lock.__index = Lock

function Lock.new(name, shared_dict)
  local self = setmetatable({}, Lock)
  self.name = name
  self.shared_dict = shared_dict
  return self
end

function Lock:lock()
  local ok, err = self.shared_dict:safe_add(self.name, 1)
  if err ~= nil and err ~= "exists" then
    ngx.log(ngx.WARN, "Error while attempting to lock " .. self.name .. ": " .. err)
  end
  return ok
end

function Lock:wait(max_retries)
  local n = max_retries or 10000
  local res = self:lock()
  while (not res and n > 0) do
    res = self:lock()
    n = n - 1
  end
  return res
end

function Lock:unlock()
  self.shared_dict:delete(self.name)
end

return Lock
