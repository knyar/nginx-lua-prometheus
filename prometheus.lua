-- vim: ts=2:sw=2:sts=2:expandtab
local Prometheus = {}
Prometheus.__index = Prometheus
Prometheus.initialized = false

-- Generate full metric name that includes all labels.
--
-- To make metric names consistent, labels are sorted in alphabetical order
-- (with the exception of "le" label which always goes last).
--
--   metric_name("omg", {foo="one", bar="two"}) => 'omg{bar="two",foo="one"}'
--
-- Args:
--   name: string
--   labels: table, mapping label keys to their values
-- Returns:
--   (string) full metric name.
local function metric_name(name, labels)
  if not labels then
    return name
  end
  local keys = {}
  for key in pairs(labels) do table.insert(keys, key) end

  -- "le" label should be the last one to ensure that all buckets for a given
  -- metric are exposed together when all metrics get sorted.
  function _label_sort(one, two)
    if two == "le" then return true end
    return one < two
  end
  table.sort(keys, _label_sort)

  local label_parts = {}
  for _, key in ipairs(keys) do
    table.insert(label_parts, key .. '="' .. labels[key] .. '"')
  end
  return name .. "{" .. table.concat(label_parts, ",") .. "}"
end

local function bucket_format(buckets)
  local max_order = 1
  local max_precision = 1
  for _, bucket in ipairs(buckets) do
    assert(type(bucket) == "number", "bucket limits should be numbers")
    local as_string = tostring(bucket)
    local dot_idx = string.find(as_string, ".", 1, true)
    if dot_idx then
      max_order = math.max(max_order, dot_idx - 1)
      max_precision = math.max(max_precision, string.len(as_string) - dot_idx)
    else
      -- this is just an integer
      max_order = math.max(max_order, string.len(as_string))
    end
  end
  return "%0" .. (max_order + max_precision + 1) .. "." .. max_precision .. "f"
end

function Prometheus.new(dict_name, latency_buckets)
  local self = setmetatable({}, Prometheus)
  self.dict = ngx.shared[dict_name or "prometheus_metrics"]
  self.initialized = true

  -- Default set of latency buckets, 5ms to 10s:
  self.latency_buckets = latency_buckets or {
    0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.2, 0.3, 0.4, 0.5, 0.75,
    1, 1.5, 2, 3, 4, 5, 10}
  self.latency_bucket_format = bucket_format(self.latency_buckets)

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

function Prometheus:set(key, value)
  local ok, err = self.dict:safe_set(key, value)
  if not ok then
    self:log_error_kv(key, value, err)
  end
end

function Prometheus:incr(key, value)
  if value < 0 then
    self:log_error_kv(key, value, "Value should not be negative")
    return
  end

  local newval, err = self.dict:incr(key, value)
  if newval then
    return
  end
  if err == "not found" then
    self:set(key, value)
    return
  end
  -- Unexpected error
  self:log_error_kv(key, value, err)
end

local function extend_table(table, another)
  if another then
    for k, v in pairs(another) do table[k] = v end
  end
  return table
end

function Prometheus:histogram_observe(name, labels, value)
  if labels and labels["le"] then
    self:log_error_kv(key, value, "'le' is not a valid label name")
    return
  end

  for _, bucket in ipairs(self.latency_buckets) do
    if value <= bucket then
      local l = extend_table(
        {le=string.format(self.latency_bucket_format, bucket)}, labels)
      self:incr(metric_name(name .. "_bucket", l), 1)
    end
  end
  -- Last bucket. Note, that the label value is "Inf" rather than "+Inf"
  -- required by Prometheus. This is necessary for this bucket to be the last
  -- one when all metrics are lexicographically sorted. "Inf" will get replaced
  -- by "+Inf" in Prometheus:collect().
  local l = extend_table({le="Inf"}, labels)
  self:incr(metric_name(name .. "_bucket", l), 1)

  self:incr(metric_name(name .. "_count", labels), 1)
  self:incr(metric_name(name .. "_sum", labels), value)
end

function Prometheus:measure(labels)
  if not self.initialized then
    ngx.log(ngx.ERR, "Prometheus module has not been initialized")
    return
  end

  local labels_with_status = extend_table({status = ngx.var.status}, labels)
  self:incr(metric_name("nginx_http_requests_total", labels_with_status), 1)

  self:histogram_observe("nginx_http_request_duration_seconds", labels,
    ngx.now() - ngx.req.start_time())
end

function Prometheus:collect()
  local keys = self.dict:get_keys(0)
  -- Prometheus server expects buckets of a histogram to appear in increasing
  -- numerical order of their label values.
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value, flags = self.dict:get(key)
    if value then
      -- Replace "Inf" with "+Inf" in each metric's last bucket 'le' label.
      ngx.say(key:gsub('le="Inf"', 'le="+Inf"'), " ", value)
    else
      self:log_error("Error getting '", key, "': ", flags)
    end
  end
end

return Prometheus
