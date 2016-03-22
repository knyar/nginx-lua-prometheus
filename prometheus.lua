-- vim: ts=2:sw=2:sts=2:expandtab
--
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
--  * all labels for a given metric are sorted by their keys, except for the
--    "le" label which always goes last;
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

-- Default set of latency buckets, 5ms to 10s:
local DEFAULT_BUCKETS = {0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3,
                         0.4, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 10}

-- Metric is a "parent class" for all metrics.
local Metric = {}
function Metric:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

-- Construct a table of labels based on label values.
--
-- This combines passed label values with label keys that were defined during
-- creation of the metric.
--
-- Args:
--   label_values: an array of label values.
--
-- Returns:
--   a table of label key/value pairs
function Metric:label_table(label_values)
  if self.label_names == nil and label_values ~= nil then
    return nil, "Expected no labels for " .. self.name .. ", got " ..
                #label_values
  elseif label_values == nil and self.label_names ~= nil then
    return nil, "Expected " .. #self.label_names .. " labels for " ..
                self.name .. ", got none"
  elseif #self.label_names ~= #label_values then
    return nil, "Wrong number of labels for " .. self.name .. ". Expected " ..
                #self.label_names .. ", got " .. #label_values
  end
  local labels = {}
  for i, label_key in ipairs(self.label_names) do
    labels[label_key] = label_values[i]
  end
  return labels, nil
end

local Counter = Metric:new()
-- Increase a given counter by `value`
--
-- Args:
--   value: (number) a value to add to the counter. Defaults to 1 if skipped.
--   label_values: an array of label values. Can be nil (i.e. not defined) for
--     metrics that have no labels.
function Counter:inc(value, label_values)
  -- fast path for metrics with no labels
  if self.label_names == nil and label_values == nil then
    self.prometheus:inc(self.name, nil, value or 1)
    return
  end
  local labels, err = self:label_table(label_values)
  if err ~= nil then
    self.prometheus:log_error(err)
    return
  end
  self.prometheus:inc(self.name, labels, value or 1)
end

local Histogram = Metric:new()
-- Record a given value in a histogram.
--
-- Args:
--   value: (number) a value to record. Should be defined.
--   label_values: an array of label values. Can be nil (i.e. not defined) for
--     metrics that have no labels.
function Histogram:observe(value, label_values)
  if value == nil then
    self.prometheus:log_error("No value passed for " .. self.name)
    return
  end
  -- fast path for metrics with no labels
  if self.label_names == nil and label_values == nil then
    self.prometheus:histogram_observe(self.name, nil, value)
    return
  end
  local labels, err = self:label_table(label_values)
  if err ~= nil then
    self.prometheus:log_error(err)
    return
  end
  self.prometheus:histogram_observe(self.name, labels, value)
end

local Prometheus = {}
Prometheus.__index = Prometheus
Prometheus.initialized = false

-- Generate full metric name that includes all labels.
--
-- To make metric names reproducible, labels are sorted in alphabetical order,
-- with the exception of "le" which always goes last.
--
-- full_metric_name("omg", {foo="one", bar="two"}) => 'omg{bar="two",foo="one"}'
--
-- Args:
--   name: string
--   labels: table, mapping label keys to their values
-- Returns:
--   (string) full metric name.
local function full_metric_name(name, labels)
  if not labels then
    return name
  end

  -- create a separate array for all keys so that we could sort them.
  local keys = {}
  for key in pairs(labels) do table.insert(keys, key) end

  -- "le" label should be the last one to ensure that all buckets for a given
  -- metric are exposed together when all metrics get sorted. This is not
  -- required by Prometheus, but makes the metrics list a bit nicer to look at.
  local function _label_sort(one, two)
    if two == "le" then return true end
    if one == "le" then return false end
    return one < two
  end
  table.sort(keys, _label_sort)

  local label_parts = {}
  for _, key in ipairs(keys) do
    table.insert(label_parts, key .. '="' .. labels[key] .. '"')
  end
  return name .. "{" .. table.concat(label_parts, ",") .. "}"
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

-- Merge table `another` into `table`.
local function extend_table(table, another)
  if another then
    for k, v in pairs(another) do table[k] = v end
  end
  return table
end

-- Initialize the module.
--
-- This should be called once from the `init_by_lua` section in nginx
-- configuration.
--
-- Args:
--   dict_name: (string) name of the nginx shared dictionary which will be
--     used to store all metrics
--
-- Returns:
--   an object that should be used to register metrics.
function Prometheus.init(dict_name)
  local self = setmetatable({}, Prometheus)
  self.dict = ngx.shared[dict_name or "prometheus_metrics"]
  self.help = {}
  self.type = {}
  self.registered = {}
  self.buckets = {}
  self.bucket_format = {}
  self.initialized = true

  self:counter("nginx_metric_errors_total",
    "Number of nginx-lua-prometheus errors")
  self.dict:set("nginx_metric_errors_total", 0)
  return self
end

function Prometheus:log_error(...)
  ngx.log(ngx.ERR, ...)
  self.dict:incr("nginx_metric_errors_total", 1)
end

function Prometheus:log_error_kv(key, value, err)
  self:log_error(
    "Error while setting '", key, "' to '", value, "': '", err, "'")
end

-- Register a counter.
--
-- Args:
--   name: (string) name of the metric. Required.
--   description: (string) description of the metric. Will be used for the HELP
--     comment on the metrics page. Optional.
--   label_names: array of strings, defining a list of metrics. Optional.
--
-- Returns:
--   a Counter object.
function Prometheus:counter(name, description, label_names)
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  if self.registered[name] then
    self:log_error("Duplicate metric " .. name)
    return
  end
  self.registered[name] = true
  self.help[name] = description
  self.type[name] = "counter"

  return Counter:new{name=name, label_names=label_names, prometheus=self}
end

-- Register a histogram.
--
-- Args:
--   name: (string) name of the metric. Required.
--   description: (string) description of the metric. Will be used for the HELP
--     comment on the metrics page. Optional.
--   label_names: array of strings, defining a list of metrics. Optional.
--   buckets: array if numbers, defining bucket boundaries. Optional.
--
-- Returns:
--   a Counter object.
function Prometheus:histogram(name, description, label_names, buckets)
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  for _, label_name in ipairs(label_names or {}) do
    if label_name == "le" then
      self:log_error("Invalid label name 'le' in " .. name)
      return
    end
  end

  for _, suffix in ipairs({"", "_bucket", "_count", "_sum"}) do
    if self.registered[name .. suffix] then
      self:log_error("Duplicate metric " .. name .. suffix)
      return
    end
    self.registered[name .. suffix] = true
  end
  self.help[name] = description
  self.type[name] = "histogram"

  self.buckets[name] = buckets or DEFAULT_BUCKETS
  self.bucket_format[name] = construct_bucket_format(self.buckets[name])

  return Histogram:new{name=name, label_names=label_names, prometheus=self}
end

-- Set a given dictionary key.
-- This overwrites existing values, so we use it only to initialize metrics.
function Prometheus:set(key, value)
  local ok, err = self.dict:safe_set(key, value)
  if not ok then
    self:log_error_kv(key, value, err)
  end
end

-- Increment a given counter by `value`.
--
-- Args:
--   name: (string) short metric name without any labels.
--   labels: (table) a table mapping label keys to values.
--   value: (number) value to add. Optional, defaults to 1.
function Prometheus:inc(name, labels, value)
  local key = full_metric_name(name, labels)
  if value == nil then value = 1 end
  if value < 0 then
    self:log_error_kv(key, value, "Value should not be negative")
    return
  end

  local newval, err = self.dict:incr(key, value)
  if newval then
    return
  end
  -- Yes, this looks like a race, so I guess we might under-report some values
  -- when multiple workers simultaneously try to create the same metric.
  -- Hopefully this does not happen too often (shared dictionary does not get
  -- reset during configuation reload).
  if err == "not found" then
    self:set(key, value)
    return
  end
  -- Unexpected error
  self:log_error_kv(key, value, err)
end

-- Record a given value into a histogram metric.
--
-- Args:
--   name: (string) short metric name without any labels.
--   labels: (table) a table mapping label keys to values.
--   value: (number) value to observe.
function Prometheus:histogram_observe(name, labels, value)
  for _, bucket in ipairs(self.buckets[name]) do
    if value <= bucket then
      local l = extend_table(
        {le=self.bucket_format[name]:format(bucket)}, labels)
      self:inc(name .. "_bucket", l, 1)
    end
  end
  -- Last bucket. Note, that the label value is "Inf" rather than "+Inf"
  -- required by Prometheus. This is necessary for this bucket to be the last
  -- one when all metrics are lexicographically sorted. "Inf" will get replaced
  -- by "+Inf" in Prometheus:collect().
  local l = extend_table({le="Inf"}, labels)
  self:inc(name .. "_bucket", l, 1)

  self:inc(name .. "_count", labels, 1)
  self:inc(name .. "_sum", labels, value)
end

-- Present all metrics in a text format compatible with Prometheus.
--
-- This function should be used to expose the metrics on a separate HTTP page.
-- It will get the metrics from the dictionary, sort them, and expose them
-- aling with TYPE and HELP comments.
function Prometheus:collect()
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  local keys = self.dict:get_keys(0)
  -- Prometheus server expects buckets of a histogram to appear in increasing
  -- numerical order of their label values.
  table.sort(keys)

  local seen_metrics = {}
  for _, key in ipairs(keys) do
    local value, err = self.dict:get(key)
    if value then
      local short_name = short_metric_name(key)
      if not seen_metrics[short_name] then
        if self.help[short_name] then
          ngx.say("# HELP " .. short_name .. " " .. self.help[short_name])
        end
        if self.type[short_name] then
          ngx.say("# TYPE " .. short_name .. " " .. self.type[short_name])
        end
        seen_metrics[short_name] = true
      end
      -- Replace "Inf" with "+Inf" in each metric's last bucket 'le' label.
      ngx.say(key:gsub('le="Inf"', 'le="+Inf"'), " ", value)
    else
      self:log_error("Error getting '", key, "': ", err)
    end
  end
end

return Prometheus
