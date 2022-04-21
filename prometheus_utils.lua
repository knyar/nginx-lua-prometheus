--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

-- Some optimization tool functions

local error            = error
local type             = type
local str_byte         = string.byte
local str_find         = string.find
local ffi              = require("ffi")
local C                = ffi.C
local ngx              = ngx
local ngx_sleep        = ngx.sleep
local select           = select

local YIELD_ITERATIONS = 500

-- copy from https://github.com/apache/apisix/blob/release/2.13/apisix/core/string.lua#L32-L34
ffi.cdef[[
    int memcmp(const void *s1, const void *s2, size_t n);
]]


local _M = {
    version = 0.1,
}

setmetatable(_M, {__index = string})

-- copy from https://github.com/apache/apisix/blob/release/2.13/apisix/core/string.lua#L47-L49
function _M.find(haystack, needle, from)
    return str_find(haystack, needle, from or 1, true)
end


-- copy form https://github.com/apache/apisix/blob/release/2.13/apisix/core/string.lua#L60-L69
function _M.has_prefix(s, prefix)
    if type(s) ~= "string" or type(prefix) ~= "string" then
        error("unexpected type: s:" .. type(s) .. ", prefix:" .. type(prefix))
    end
    if #s < #prefix then
        return false
    end
    local rc = C.memcmp(s, prefix, #prefix)
    return rc == 0
end


-- copy form https://github.com/apache/apisix/blob/release/2.13/apisix/core/table.lua#L50-L58
function _M.insert_tail(tab, ...)
    local idx = #tab
    for i = 1, select('#', ...) do
        idx = idx + 1
        tab[idx] = select(i, ...)
    end

    return idx
end


-- copy form https://github.com/Kong/kong/blob/2.8.1/kong/tools/utils.lua#L1430-L1446
-- remove phase, default is log_by_lua phase
do
  local counter = 0
  function _M.yield(in_loop)
    if in_loop then
      counter = counter + 1
      if counter % YIELD_ITERATIONS ~= 0 then
        return
      end
      counter = 0
    end
    ngx_sleep(0)
  end
end


return _M
