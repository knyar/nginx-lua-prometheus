-- vim: ts=2:sw=2:sts=2:expandtab
luaunit = require('luaunit')
prometheus = require('prometheus')

-- Simple implementation of a nginx shared dictionary
local SimpleDict = {}
SimpleDict.__index = SimpleDict
function SimpleDict:set(k, v)
  if not self.dict then self.dict = {} end
  self.dict[k] = v
  return true, nil, false  -- success, err, forcible
end
function SimpleDict:safe_set(k, v)
  if k:find("willnotfit") then
    return nil, "no memory"
  end
  self:set(k, v)
  return true, nil  -- ok, err
end
function SimpleDict:incr(k, v)
  if not self.dict[k] then return nil, "not found" end
  self.dict[k] = self.dict[k] + v
  return self.dict[k], nil  -- newval, err
end
function SimpleDict:get(k)
  return self.dict[k], 0  -- value, flags
end
function SimpleDict:get_keys(k)
  local keys = {}
  for key in pairs(self.dict) do table.insert(keys, key) end
  return keys
end

-- Global nginx object
local Nginx = {}
Nginx.__index = Nginx
Nginx.ERR = {}
Nginx.WARN = {}
function Nginx.log(level, ...)
  if not ngx.logs then ngx.logs = {} end
  table.insert(ngx.logs, table.concat(arg, " "))
end
function Nginx.say(...)
  if not ngx.said then ngx.said = {} end
  table.insert(ngx.said, table.concat(arg, ""))
end

-- Finds index of a given object in a table
local function find_idx(table, element)
  for idx, value in pairs(table) do
    if value == element then
      return idx
    end
  end
end

TestPrometheus = {}
function TestPrometheus:setUp()
  self.dict = setmetatable({}, SimpleDict)
  ngx = setmetatable({shared={metrics=self.dict}}, Nginx)
end
function TestPrometheus:testInit()
  local p = prometheus.init("metrics")
  assertEquals(self.dict:get("nginx_metric_errors_total"), 0)
  assertEquals(ngx.logs, nil)
end
function TestPrometheus:testErrorUnitialized()
  local p = prometheus
  p:incr("m1", nil, 1)
  p:histogram_observe("l1", nil, 0.35)

  assertEquals(table.getn(ngx.logs), 2)
end
function TestPrometheus:testErrorNoMemory()
  local p = prometheus.init("metrics")
  p:incr("metric1", nil, 5)
  p:incr("willnotfit", nil, 1)

  assertEquals(self.dict:get("metric1"), 5)
  assertEquals(self.dict:get("nginx_metric_errors_total"), 1)
  assertEquals(self.dict:get("willnotfit"), nil)
  assertEquals(table.getn(ngx.logs), 1)
end
function TestPrometheus:testErrorNegativeValue()
  local p = prometheus.init("metrics")
  p:incr("metric1", nil, -5)

  assertEquals(self.dict:get("metric1"), nil)
  assertEquals(self.dict:get("nginx_metric_errors_total"), 1)
  assertEquals(table.getn(ngx.logs), 1)
end
function TestPrometheus:testErrorInvalidLabels()
  local p = prometheus.init("metrics")
  p:histogram_observe("l1", {le="ok"}, 0.001)

  assertEquals(self.dict:get("l1"), nil)
  assertEquals(self.dict:get("nginx_metric_errors_total"), 1)
  assertEquals(table.getn(ngx.logs), 1)
end
function TestPrometheus:testErrorInvalidBucketer()
  local p = prometheus.init("metrics")
  p:histogram_observe("l1", {site="site1"}, 0.001, "bucketer")

  assertEquals(self.dict:get("l1"), nil)
  assertEquals(self.dict:get("nginx_metric_errors_total"), 1)
  assertEquals(table.getn(ngx.logs), 1)
end
function TestPrometheus:testCounters()
  local p = prometheus.init("metrics")
  p:incr("metric1", nil, 5)
  p:incr("metric2", {f2="v2", f1="v1"}, 2)
  p:incr("metric2", {f2="v2", f1="v1"}, 2)

  assertEquals(self.dict:get("metric1"), 5)
  assertEquals(self.dict:get('metric2{f1="v1",f2="v2"}'), 4)
  assertEquals(ngx.logs, nil)
end
function TestPrometheus:testLatencyHistogram()
  local p = prometheus.init("metrics")
  p:histogram_observe("l1", nil, 0.35)
  p:histogram_observe("l1", nil, 0.4)
  p:histogram_observe("l1", {var="ok", site="site1"}, 0.001)
  p:histogram_observe("l1", {var="ok", site="site1"}, 0.15)

  assertEquals(self.dict:get('l1_bucket{le="00.300"}'), nil)
  assertEquals(self.dict:get('l1_bucket{le="00.400"}'), 2)
  assertEquals(self.dict:get('l1_bucket{le="00.500"}'), 2)
  assertEquals(self.dict:get('l1_bucket{le="Inf"}'), 2)
  assertEquals(self.dict:get('l1_count'), 2)
  assertEquals(self.dict:get('l1_sum'), 0.75)
  assertEquals(self.dict:get('l1_bucket{site="site1",var="ok",le="00.005"}'), 1)
  assertEquals(self.dict:get('l1_bucket{site="site1",var="ok",le="00.100"}'), 1)
  assertEquals(self.dict:get('l1_bucket{site="site1",var="ok",le="00.200"}'), 2)
  assertEquals(self.dict:get('l1_bucket{site="site1",var="ok",le="Inf"}'), 2)
  assertEquals(self.dict:get('l1_count{site="site1",var="ok"}'), 2)
  assertEquals(self.dict:get('l1_sum{site="site1",var="ok"}'), 0.151)
  assertEquals(ngx.logs, nil)
end
function TestPrometheus:testCustomLatencyBucketer1()
  local p = prometheus.init("metrics", {latency={1,2,3}})
  p:histogram_observe("l1", {var="ok"}, 2)
  p:histogram_observe("l1", {var="ok"}, 0.151)

  assertEquals(self.dict:get('l1_bucket{var="ok",le="1.0"}'), 1)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="2.0"}'), 2)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="3.0"}'), 2)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="Inf"}'), 2)
  assertEquals(self.dict:get('l1_count{var="ok"}'), 2)
  assertEquals(self.dict:get('l1_sum{var="ok"}'), 2.151)
  assertEquals(ngx.logs, nil)
end
function TestPrometheus:testCustomLatencyBucketer2()
  local p = prometheus.init("metrics", {latency={0.000005,5,50000}})
  p:histogram_observe("l1", {var="ok"}, 0.000001)
  p:histogram_observe("l1", {var="ok"}, 3)
  p:histogram_observe("l1", {var="ok"}, 7)
  p:histogram_observe("l1", {var="ok"}, 70000)

  assertEquals(self.dict:get('l1_bucket{var="ok",le="00000.000005"}'), 1)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="00005.000000"}'), 2)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="50000.000000"}'), 3)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="Inf"}'), 4)
  assertEquals(self.dict:get('l1_count{var="ok"}'), 4)
  assertEquals(self.dict:get('l1_sum{var="ok"}'), 70010.000001)
  assertEquals(ngx.logs, nil)
end
function TestPrometheus:testCustomAdditionalBucketer()
  local p = prometheus.init("metrics", {bytes={100, 2000}})
  p:histogram_observe("l1", {var="ok"}, 0.000001)
  p:histogram_observe("l1", {var="ok"}, 3)
  p:histogram_observe("l1", {var="ok"}, 7)
  p:histogram_observe("l1", {var="ok"}, 70000)
  p:histogram_observe("b1", {var="ok"}, 50, "bytes")
  p:histogram_observe("b1", {var="ok"}, 50, "bytes")
  p:histogram_observe("b1", {var="ok"}, 150, "bytes")
  p:histogram_observe("b1", {var="ok"}, 5000, "bytes")

  assertEquals(self.dict:get('l1_bucket{var="ok",le="00.005"}'), 1)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="04.000"}'), 2)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="10.000"}'), 3)
  assertEquals(self.dict:get('l1_bucket{var="ok",le="Inf"}'), 4)
  assertEquals(self.dict:get('l1_count{var="ok"}'), 4)
  assertEquals(self.dict:get('l1_sum{var="ok"}'), 70010.000001)

  assertEquals(self.dict:get('b1_bucket{var="ok",le="0100.0"}'), 2)
  assertEquals(self.dict:get('b1_bucket{var="ok",le="2000.0"}'), 3)
  assertEquals(self.dict:get('b1_bucket{var="ok",le="Inf"}'), 4)
  assertEquals(self.dict:get('b1_count{var="ok"}'), 4)
  assertEquals(self.dict:get('b1_sum{var="ok"}'), 5250)
  assertEquals(ngx.logs, nil)
end
function TestPrometheus:testCollect()
  local p = prometheus.init("metrics", {bytes={100, 2000}})
  p:incr("metric1", nil, 5)
  p:incr("metric2", {f2="v2", f1="v1"}, 2)
  p:incr("metric2", {f2="v2", f1="v1"}, 2)
  p:histogram_observe("l1", {var="ok"}, 0.000001)
  p:histogram_observe("l1", {var="ok"}, 3)
  p:histogram_observe("l1", {var="ok"}, 7)
  p:histogram_observe("l1", {var="ok"}, 70000)
  p:histogram_observe("b1", {var="ok"}, 50, "bytes")
  p:histogram_observe("b1", {var="ok"}, 50, "bytes")
  p:histogram_observe("b1", {var="ok"}, 150, "bytes")
  p:histogram_observe("b1", {var="ok"}, 5000, "bytes")
  p:collect()

  assert(find_idx(ngx.said, "metric1 5") ~= nil)
  assert(find_idx(ngx.said, 'metric2{f1="v1",f2="v2"} 4') ~= nil)

  assert(find_idx(ngx.said, 'b1_bucket{var="ok",le="0100.0"} 2') ~= nil)
  assert(find_idx(ngx.said, 'b1_sum{var="ok"} 5250') ~= nil)

  assert(find_idx(ngx.said, 'l1_bucket{var="ok",le="04.000"} 2') ~= nil)
  assert(find_idx(ngx.said, 'l1_bucket{var="ok",le="+Inf"} 4') ~= nil)

  -- check that type comment exists and is before any samples for the metric.
  local type_idx = find_idx(ngx.said, '# TYPE l1 histogram')
  assert (type_idx ~= nil)
  assert (ngx.said[type_idx-1]:find("^l1") == nil)
  assert (ngx.said[type_idx+1]:find("^l1") ~= nil)
  assertEquals(ngx.logs, nil)
end

os.exit(luaunit.run())
