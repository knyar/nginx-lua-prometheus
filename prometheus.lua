--- @module Prometheus
--
-- vim: ts=2:sw=2:sts=2:expandtab
-- This module uses a single dictionary shared between Nginx workers to keep
-- all metrics. Each counter is stored as a separate entry in that dictionary,
-- which allows us to increment them using built-in `incr` method.
--
-- Prometheus requires that (a) all samples for a given metric are presented
-- as one uninterrupted group, and (b) buckets of a histogram appear in
-- increasing numerical order. We satisfy that by carefully constructing full
-- metric names (i.e. metric name along with all labels) so that they meet
-- those requirements while being sorted alphabetically. In particular:
--
--  * all labels for a given metric are presented in reproducible order (the one
--    used when labels were declared). "le" label for histogram metrics always
--    goes last;
--  * bucket boundaries (which are exposed as values of the "le" label) are
--    presented as floating point numbers with leading and trailing zeroes.
--    Number of of zeroes is determined for each bucketer automatically based on
--    bucket boundaries;
--  * internally "+Inf" bucket is stored as "Inf" (to make it appear after
--    all numeric buckets), and gets replaced by "+Inf" just before we
--    expose the metrics.
--
-- For example, if you define your bucket boundaries as {0.00005, 10, 1000}
-- then we will keep the following samples for a metric `m1` with label
-- `site` set to `site1`:
--
--   m1_bucket{site="site1",le="0000.00005"}
--   m1_bucket{site="site1",le="0010.00000"}
--   m1_bucket{site="site1",le="1000.00000"}
--   m1_bucket{site="site1",le="Inf"}
--   m1_count{site="site1"}
--   m1_sum{site="site1"}
--
-- "Inf" will be replaced by "+Inf" while publishing metrics.
--
-- You can find the latest version and documentation at
-- https://github.com/knyar/nginx-lua-prometheus
-- Released under MIT license.

local resty_counter_lib = require("prometheus.resty_counter")

local Prometheus = {}
local mt = { __index = Prometheus }

local TYPE_COUNTER    = 0x1
local TYPE_GAUGE      = 0x2
local TYPE_HISTOGRAM  = 0x4
local TYPE_LITERAL = {
  [TYPE_COUNTER]   = "counter",
  [TYPE_GAUGE]     = "gauge",
  [TYPE_HISTOGRAM] = "histogram",
}
local KEY_METRIC = mt -- dummy key for lookup

-- the metrics name used for the client library itself
local ERROR_METRIC_NAME = "nginx_metric_errors_total"

-- Default set of latency buckets, 5ms to 10s:
local DEFAULT_BUCKETS = {0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3,
                         0.4, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 10}

-- Generate full metric name that includes all labels.
--
-- Args:
--   name: string
--   label_names: (array) a list of label keys.
--   label_values: (array) a list of label values.
-- Returns:
--   (string) full metric name.
local function full_metric_name(name, label_names, label_values)
  if not label_names then
    return name
  end
  local label_parts = {}
  for idx, key in ipairs(label_names) do
    local label_value = (string.format("%s", label_values[idx])
      :gsub("[^\032-\126]", "")  -- strip non-printable characters
      :gsub("\\", "\\\\")
      :gsub('"', '\\"'))
    table.insert(label_parts, key .. '="' .. label_value .. '"')
  end
  return name .. "{" .. table.concat(label_parts, ",") .. "}"
end

-- Extract short metric name from the full one.
--
-- Args:
--   full_name: (string) full metric name that can include labels.
--
-- Returns:
--   (string) short metric name with no labels. For a `*_bucket` metric of
--     histogram the _bucket suffix will be removed.
local function short_metric_name(full_name)
  local labels_start, _ = full_name:find("{")
  if not labels_start then
    -- no labels
    return full_name
  end
  local suffix_idx, _ = full_name:find("_bucket{")
  if suffix_idx and full_name:find("le=") then
    -- this is a histogram metric
    return full_name:sub(1, suffix_idx - 1)
  end
  -- this is not a histogram metric
  return full_name:sub(1, labels_start - 1)
end

-- Check metric name and label names for correctness.
--
-- Regular expressions to validate metric and label names are
-- documented in https://prometheus.io/docs/concepts/data_model/
--
-- Args:
--   metric_name: (string) metric name.
--   label_names: label names (array of strings).
--
-- Returns:
--   Either an error string, or nil of no errors were found.
local function check_metric_and_label_names(metric_name, label_names)
  if not metric_name:match("^[a-zA-Z_:][a-zA-Z0-9_:]*$") then
    return "Metric name '" .. metric_name .. "' is invalid"
  end
  for _, label_name in ipairs(label_names or {}) do
    if label_name == "le" then
      return "Invalid label name 'le' in " .. metric_name
    end
    if not label_name:match("^[a-zA-Z_][a-zA-Z0-9_]*$") then
      return "Metric '" .. metric_name .. "' label name '" .. label_name ..
             "' is invalid"
    end
  end
end

-- Construct bucket format for a list of buckets.
--
-- This receives a list of buckets and returns a sprintf template that should
-- be used for bucket boundaries to make them come in increasing order when
-- sorted alphabetically.
--
-- To re-phrase, this is where we detect how many leading and trailing zeros we
-- need.
--
-- Args:
--   buckets: a list of buckets
--
-- Returns:
--   (string) a sprintf template.
local function construct_bucket_format(buckets)
  local max_order = 1
  local max_precision = 1
  for _, bucket in ipairs(buckets) do
    assert(type(bucket) == "number", "bucket boundaries should be numeric")
    -- floating point number with all trailing zeros removed
    local as_string = string.format("%f", bucket):gsub("0*$", "")
    local dot_idx = as_string:find(".", 1, true)
    max_order = math.max(max_order, dot_idx - 1)
    max_precision = math.max(max_precision, as_string:len() - dot_idx)
  end
  return "%0" .. (max_order + max_precision + 1) .. "." .. max_precision .. "f"
end

-- begins metrics functions

local function lookup_or_create(self, label_values)
  -- if user accidently put a `nil` in between, #label_values will
  -- return the non-nil prefix of the list, thus we will
  -- be able to catch that situation as well
  local cnt = label_values and #label_values or 0
  -- specially, if first element is nil, # will treat it as "non-empty"
  if cnt ~= self.label_count or (self.label_count > 0 and not label_values[1]) then
    return nil, string.format("inconsistent labels count, expected %d, got %d",
                              self.label_count, cnt)
  end
  local t = self.lookup
  if label_values then
    -- Don't use ipairs here to avoid inner loop generates trace first
    -- Otherwise the inner for loop below is likely to get JIT compiled before
    -- the outer loop which include `lookup_or_create`, in this case the trace
    -- for outer loop will be aborted. By not using ipairs, we will be able to
    -- compile longer traces as possible.
    local label
    for i=1,self.label_count do
      label = label_values[i]
      if not t[label] then
        t[label] = {}
      end
      t = t[label]
    end
  end
  local key = t[KEY_METRIC]
  if key then
    return key
  end
  -- the following will only run once per labels combination per worker
  -- TODO: further optimize this?
  if self.typ == TYPE_HISTOGRAM then
    local formatted = full_metric_name("", self.label_names, label_values)
    key = {
      self.name .. "_count" .. formatted,
      self.name .. "_sum" .. formatted,
    }

    local bucket_pref
    if self.label_count > 0 then
      -- strip last }
      bucket_pref = self.name .. "_bucket" .. string.sub(formatted, 1, #formatted-1) .. ","
    else
      bucket_pref = self.name .. "_bucket{"
    end

    for i, buc in ipairs(self.bucket) do
      key[i+2] = string.format("%sle=\"%s\"}", bucket_pref, self.bucket_format:format(buc))
    end
    -- Last bucket. Note, that the label value is "Inf" rather than "+Inf"
    -- required by Prometheus. This is necessary for this bucket to be the last
    -- one when all metrics are lexicographically sorted. "Inf" will get replaced
    -- by "+Inf" in Prometheus:collect().
    key[self.bucket_count+3] = string.format("%sle=\"Inf\"}", bucket_pref)
  else
    key = full_metric_name(self.name, self.label_names, label_values)
  end
  t[KEY_METRIC] = key
  return key
end

local ERR_MSG_COUNTER_NOT_INITIALIZED = "counter not initialied"

local function inc(self, value, label_values)
  -- counter is not allowed to decrease
  if self.typ == TYPE_COUNTER and value and value < 0 then
    self._log_error_kv(self.name, value, "Value should not be negative")
    return
  end

  local k, err
  k, err = lookup_or_create(self, label_values)
  if err then
    self._log_error(err)
    return
  end
  -- FIXME: counter is initialized in init_worker while metrics are initiliazed
  -- in init phase
  local c = self._counter
  if not c then
    c = self.parent._counter
    if not c then
      self._log_error(ERR_MSG_COUNTER_NOT_INITIALIZED)
      return
    end
    self._counter = c
  end
  c:incr(k, value, 0)
end

local function del(self, label_values)
  local k, _, err
  k, err = lookup_or_create(self, label_values)
  if err then
    self._log_error(err)
    return
  end

  ngx.log(ngx.INFO, "waiting ", self.parent.sync_interval, "s for counter to sync")
  ngx.sleep(self.parent.sync_interval)
  _, err = self._dict:delete(k)
  if err then
    self._log_error("Error deleting key: ".. k .. ": " .. err)
  end
end

local function set(self, value, label_values)
  if not value then
    self._log_error("No value passed for " .. self.name)
    return
  end

  local k, _, err
  k, err = lookup_or_create(self, label_values)
  if err then
    self._log_error(err)
    return
  end
  _, err = self._dict:safe_set(k, value)
  if err then
    self._log_error_kv(k, value, err)
  end
end

local function observe(self, value, label_values)
  if not value then
    self._log_error("No value passed for " .. self.name)
    return
  end

  local keys, err = lookup_or_create(self, label_values)
  if err then
    self._log_error(err)
    return
  end
  -- FIXME: counter is initialized in init_worker while metrics are initiliazed
  -- in init phase
  local c = self._counter
  if not c then
    c = self.parent._counter
    if not c then
      self._log_error(ERR_MSG_COUNTER_NOT_INITIALIZED)
      return
    end
    self._counter = c
  end

  -- count
  c:incr(keys[1], 1, 0)

  -- sum
  c:incr(keys[2], value, 0)

  local seen = false
  -- check in reverse order, otherwise we will always
  -- need to traverse the whole table.
  for i=self.bucket_count, 1, -1 do
    if value <= self.bucket[i] then
      c:incr(keys[2+i], 1, 0)
      seen = true
    elseif seen then
      break
    end
  end
  -- inf
  c:incr(keys[self.bucket_count+3], 1, 0)
end

local function reset(self)
  ngx.log(ngx.INFO, "waiting ", self.parent.sync_interval, "s for counter to sync")
  ngx.sleep(self.parent.sync_interval)

  local keys = self._dict:get_keys(0)
  local name_prefix = self.name .. "{"
  local name_prefix_length = #name_prefix

  for _, key in ipairs(keys) do
    local value, err = self._dict:get(key)
    if value then
      -- with out labels equal, or with labels and the part before { equals
      if key == self.name or name_prefix == string.sub(key, 1, name_prefix_length) then
        _, err = self._dict:safe_set(key, nil)
        if err then
          self._log_error("Error resetting '", key, "': ", err)
        end
      end
    else
      self._log_error("Error getting '", key, "': ", err)
    end
  end

  -- clean up lookup table as well
  self.lookup = {}
end

-- ends metrics functions

function Prometheus.init(dict_name, prefix, sync_interval)
  local self = setmetatable({}, mt)
  dict_name = dict_name or "prometheus_metrics"
  self.dict_name = dict_name
  self.dict = ngx.shared[dict_name]
  if self.dict == nil then
    error("Dictionary '" .. dict_name .. "' does not seem to exist. " ..
      "Please define the dictionary using `lua_shared_dict`.", 2)
  end

  if prefix then
    self.prefix = prefix
  else
    self.prefix = ''
  end

  self.registry = {}

  self.initialized = true

  self:counter(ERROR_METRIC_NAME,
    "Number of nginx-lua-prometheus errors")
  self.dict:set(ERROR_METRIC_NAME, 0)

  -- sync interval for lua-resty-counter
  self.sync_interval = sync_interval or 1
  return self
end

function Prometheus:init_worker()
  local counter_instance, err = resty_counter_lib.new(self.dict_name, self.sync_interval)
  if err then
    error(err, 2)
  end
  self._counter = counter_instance
end

local function register(self, name, help, label_names, buckets, typ)
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  local err = check_metric_and_label_names(name, label_names)
  if err then
    self:log_error(err)
    return
  end

  local name_maybe_historgram = name:gsub("_bucket$", "")
                                    :gsub("_count$", "")
                                    :gsub("_sum$", "")
  if (self.typ ~= TYPE_HISTOGRAM and (
      self.registry[name] or self.registry[name_maybe_historgram]
    )) or
    (self.typ == TYPE_HISTOGRAM and (
      self.registry[name] or
      self.registry[name .. "_count"] or
      self.registry[name .. "_sum"] or self.registry[name .. "_bucket"]
    )) then

    self:log_error("Duplicate metric " .. name)
    return
  end

  local metric = {
    name = name,
    help = help,
    typ = typ,
    label_names = label_names,
    label_count = label_names and #label_names or 0,
    -- TODO: lru cache with auto ttl?
    -- lookup is a tree of label values used to cache full metric names
    lookup = {},
    parent = self,
    -- store a reference for faster lookup
    _log_error = function(...) self:log_error(...) end,
    _log_error_kv = function(...) self:log_error_kv(...) end,
    _dict = self.dict,
    -- populate functions
    -- TODO: how does it compare with metatable lookup cpu/memory-ise?
  }
  if typ < TYPE_HISTOGRAM then
    if typ == TYPE_GAUGE then
      metric.set = set
    end
    metric.inc = inc
    metric.reset = reset
    metric.del = del
  else
    metric.observe = observe
    metric.bucket = buckets or DEFAULT_BUCKETS
    metric.bucket_count = #metric.bucket
    metric.bucket_format = construct_bucket_format(metric.bucket)
  end

  self.registry[name] = metric
  return metric
end

function Prometheus:counter(name, help, label_names)
  return register(self, name, help, label_names, nil, TYPE_COUNTER)
end

function Prometheus:gauge(name, help, label_names)
  return register(self, name, help, label_names, nil, TYPE_GAUGE)
end

function Prometheus:histogram(name, help, label_names, buckets)
  return register(self, name, help, label_names, buckets, TYPE_HISTOGRAM)
end

-- Prometheus compatible metric data as an array of strings.
--
-- Returns:
--   Array of strings with all metrics in a text format compatible with
--   Prometheus.
function Prometheus:metric_data()
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  -- force a manual sync of counter local state to make integration test working
  self._counter:sync()

  local keys = self.dict:get_keys(0)
  -- Prometheus server expects buckets of a histogram to appear in increasing
  -- numerical order of their label values.
  table.sort(keys)

  local seen_metrics = {}
  local output = {}
  for _, key in ipairs(keys) do
    local value, err = self.dict:get(key)
    if value then
      local short_name = short_metric_name(key)
      if not seen_metrics[short_name] then
        local m = self.registry[short_name]
        if m then
          if m.help then
            table.insert(output, string.format("# HELP %s%s %s\n",
            self.prefix, short_name, m.help))
          end
          if m.typ then
            table.insert(output, string.format("# TYPE %s%s %s\n",
              self.prefix, short_name, TYPE_LITERAL[m.typ]))
          end
        end
        seen_metrics[short_name] = true
      end
      -- Replace "Inf" with "+Inf" in each metric's last bucket 'le' label.
      if key:find('le="Inf"', 1, true) then
        key = key:gsub('le="Inf"', 'le="+Inf"')
      end
      table.insert(output, string.format("%s%s %s\n", self.prefix, key, value))
    else
      self:log_error("Error getting '", key, "': ", err)
    end
  end
  return output
end

-- Present all metrics in a text format compatible with Prometheus.
--
-- This function should be used to expose the metrics on a separate HTTP page.
-- It will get the metrics from the dictionary, sort them, and expose them
-- aling with TYPE and HELP comments.
function Prometheus:collect()
  ngx.header.content_type = "text/plain"
  ngx.print(self:metric_data())
end

function Prometheus:log_error(...)
  ngx.log(ngx.ERR, ...)
  self._counter:incr(ERROR_METRIC_NAME, 1, 0)
end

function Prometheus:log_error_kv(key, value, err)
  self:log_error(
    "Error while setting '", key, "' to '", value, "': '", err, "'")
end

return Prometheus
