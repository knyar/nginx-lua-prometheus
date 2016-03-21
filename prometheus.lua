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
  -- metric are exposed together when all metrics get sorted.
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

-- Construct bucket format for a list of bucketers.
--
-- This receives a table mapping bucketer name to a list of buckets and returns
-- a sprintf template that should be used for bucket boundaries of each
-- bucketer to make them come in increasing order when sorted alphabetically.
--
-- To re-phrase, this is where we detect how many leading and trailing zeros we
-- need.
--
-- Args:
--   bucketers: a table mapping bucketer name to a list of buckets
--
-- Returns:
--   a table mapping bucketer name to a sprintf template.
local function construct_bucket_format(bucketers)
  local bucket_formats = {}
  for bucketer, buckets in pairs(bucketers) do
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
    bucket_formats[bucketer] = "%0" .. (max_order + max_precision + 1) ..
      "." .. max_precision .. "f"
  end
  return bucket_formats
end

-- Merges table `another` into `table`.
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
--   bucketers: (table) a map from bucketer name to a list of bucket
--     boundaries.
--
-- Returns:
--   an object that should be used to measure and collect the metrics.
function Prometheus.init(dict_name, bucketers)
  local self = setmetatable({}, Prometheus)
  self.dict = ngx.shared[dict_name or "prometheus_metrics"]
  self.initialized = true

  -- Default set of latency buckets, 5ms to 10s:
  self.bucketers = extend_table({
    latency={0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3, 0.4, 0.5,
             0.75, 1, 1.5, 2, 3, 4, 5, 10}
  }, bucketers)
  self.bucket_format = construct_bucket_format(self.bucketers)

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
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

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
--   bucketer: (string) name of a bucketer to use. Default latency bucketer
--     will be used if unspecified.
function Prometheus:histogram_observe(name, labels, value, bucketer)
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  if labels and labels["le"] then
    self:log_error_kv(name, value, "'le' is not a valid label name")
    return
  end

  bucketer = bucketer or "latency"
  if self.bucketers[bucketer] == nil then
    self:log_error_kv(name, value, bucketer .. " is not a valid bucketer")
    return
  end

  for _, bucket in ipairs(self.bucketers[bucketer]) do
    if value <= bucket then
      local l = extend_table(
        {le=self.bucket_format[bucketer]:format(bucket)}, labels)
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

-- Provide some default measurements.
-- Args:
--   labels: (table) a table mapping label keys to values. Optional.
function Prometheus:measure(labels)
  local labels_with_status = extend_table({status = ngx.var.status}, labels)
  self:inc("nginx_http_requests_total", labels_with_status, 1)

  self:histogram_observe("nginx_http_request_duration_seconds", labels,
    ngx.now() - ngx.req.start_time())
end

-- Present all metrics in a text format compatible with Prometheus.
--
-- This function should be used to expose the metrics on a separate HTTP page.
-- It will get the metrics from the dictionary, sort them, and provide TYPE
-- declarations for all histograms.
function Prometheus:collect()
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  local keys = self.dict:get_keys(0)
  -- Prometheus server expects buckets of a histogram to appear in increasing
  -- numerical order of their label values.
  table.sort(keys)

  local seen_histograms = {}
  for _, key in ipairs(keys) do
    local value, err = self.dict:get(key)
    if value then
      -- Check if this is one of the buckets of a histogram metric.
      local bucket_suffix, _ = key:find("_bucket{")
      if bucket_suffix and key:find("le=") then
        -- Prometheus expects all histograms to have a type declaration.
        local metric_name = key:sub(1, bucket_suffix - 1)
        if not seen_histograms[metric_name] then
          ngx.say("# TYPE " .. metric_name .. " histogram")
          seen_histograms[metric_name] = true
        end
      end
      -- Replace "Inf" with "+Inf" in each metric's last bucket 'le' label.
      ngx.say(key:gsub('le="Inf"', 'le="+Inf"'), " ", value)
    else
      self:log_error("Error getting '", key, "': ", err)
    end
  end
end

return Prometheus
