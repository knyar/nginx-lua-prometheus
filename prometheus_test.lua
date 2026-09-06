-- vim: ts=2:sw=2:sts=2:expandtab
luaunit = require('luaunit')
rex_pcre2 = require('rex_pcre2')

-- Simple implementation of a nginx shared dictionary
local SimpleDict = {}
SimpleDict.__index = SimpleDict
function SimpleDict:set(k, v)
  local forcible = false
  if k == "willnotfitk" or v == "willnotfitv" then
    forcible = true
  end
  if not self.dict then self.dict = {} end
  self.dict[k] = v
  return true, nil, forcible
end
function SimpleDict:add(k, v)
  local forcible = false
  if k == "willnotfitk" or v == "willnotfitv" then
    forcible = true
  end
  self:set(k, v)
  return true, nil, forcible  -- ok, err, forcible
end
function SimpleDict:incr(k, v, init)
  local forcible = false
  if k == "willnotfitk" or v == "willnotfitv" then
    forcible = true
  end
  if not self.dict[k] then self.dict[k] = init end
  self.dict[k] = self.dict[k] + (v or 1)
  return self.dict[k], nil, forcible  -- newval, err, forcible
end
function SimpleDict:get(k)
  -- simulate key not exist
  if k == "gauge2{f2=\"key_not_exist\",f1=\"key_not_exist\"}" then
    return nil, nil
  end
  -- simulate an error
  if k == "gauge2{f2=\"dict_error\",f1=\"dict_error\"}" then
    return nil, "dict error"
  end
  if not self.dict then self.dict = {} end
  return self.dict[k], nil  -- value, err
end
function SimpleDict:delete(k)
  self.dict[k] = nil
end

-- Global nginx object
local Nginx = {}
Nginx.__index = Nginx
Nginx.ERR = {}
Nginx.WARN = {}
Nginx.DEBUG = {}
Nginx.header = {}
function Nginx.log(level, ...)
  if level == ngx.DEBUG then return end
  if not ngx.logs then ngx.logs = {} end
  table.insert(ngx.logs, table.concat({...}, " "))
end
function Nginx.print(printed)
  if not ngx.printed then ngx.printed = {} end
  for str in string.gmatch(table.concat(printed, ""), "([^\n]+)") do
    table.insert(ngx.printed, str)
  end
end
Nginx.worker = {}
function Nginx.worker.id()
  return 'testworker'
end
-- Tests only need distinct, deterministic keys for different bucket layouts.
function Nginx.md5(value) return value end
function Nginx.sleep() end
Nginx.timer = {}
function Nginx.timer.every(_, _, _) end
function Nginx.get_phase()
  return 'init_worker'
end
Nginx.re = {}
function Nginx.re.match(subject, regexp, _)
  local result = {rex_pcre2.match(subject, regexp)}
  if result[1] == nil or result[1] == false then
    return nil, nil
  end
  return result, nil
end
function Nginx.re.gsub(subject, regexp, replace, _)
  local result, _, substitutions = rex_pcre2.gsub(subject, regexp, replace)
  return result, substitutions, nil
end

ngx = setmetatable({shared={}}, Nginx)

-- Finds index of a given object in a table
local function find_idx(table, element)
  for idx, value in pairs(table) do
    if value == element then
      return idx
    end
  end
end

-- Read the public exposition instead of depending on histogram storage keys.
local function samples(prometheus)
  local result = {}
  for _, line in ipairs(prometheus:metric_data()) do
    if line:sub(1, 1) ~= "#" then
      local key, value = line:match("^(.-) ([^ ]+)\n$")
      luaunit.assertEquals(result[key], nil, "duplicate sample: " .. key)
      result[key] = assert(tonumber(value))
    end
  end
  return result
end

local function sample(prometheus, key)
  return samples(prometheus)[key]
end

TestPrometheus = {}
function TestPrometheus:setUp()
  self.dict = setmetatable({}, SimpleDict)
  ngx.shared.metrics = self.dict
  self.p = require('prometheus').init('metrics')
  -- Another instance of the library to simulate a second nginx worker.
  self.p2 = require('prometheus').init('metrics')
  self.counter1 = self.p:counter("metric1", "Metric 1")
  self.counter2 = self.p:counter("metric2", "Metric 2", {"f2", "f1"})
  self.counter3 = self.p:counter("metric3", "Metric 3", {"f3"})
  self.counter4 = self.p:counter("metric4", "Metric 4", {"f1","f2","f3"})
  self.gauge1 = self.p:gauge("gauge1", "Gauge 1")
  self.gauge1_p2 = self.p2:gauge("gauge1", "Gauge 1")
  self.gauge2 = self.p:gauge("gauge2", "Gauge 2", {"f2", "f1"})
  self.gauge2_p2 = self.p2:gauge("gauge2", "Gauge 2", {"f2", "f1"})
  self.hist1 = self.p:histogram("l1", "Histogram 1")
  self.hist1_p2 = self.p2:histogram("l1", "Histogram 1")
  self.hist2 = self.p:histogram("l2", "Histogram 2", {"var", "site"})
end
function TestPrometheus.tearDown()
  ngx.logs = nil
end
function TestPrometheus:testInit()
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)
  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testInitOptions()
  self.dict = setmetatable({}, SimpleDict)
  ngx.shared.metrics = self.dict

  local p1 = require('prometheus').init("metrics")
  assert(p1.prefix == "")
  assert(p1.sync_interval == 1)
  assert(p1.error_metric_name == "nginx_metric_errors_total")

  local p2 = require('prometheus').init("metrics", "test_pref_")
  assert(p2.prefix == "test_pref_")
  assert(p2.sync_interval == 1)
  assert(p2.error_metric_name == "nginx_metric_errors_total")

  local p3 = require('prometheus').init("metrics", {sync_interval=3})
  assert(p3.prefix == "")
  assert(p3.sync_interval == 3)
  assert(p3.error_metric_name == "nginx_metric_errors_total")

  local p4 = require('prometheus').init("metrics", {
    prefix="foo", sync_interval=3, error_metric_name="foobar"})
  assert(p4.prefix == "foo")
  assert(p4.sync_interval == 3)
  assert(p4.error_metric_name == "foobar")

  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testInitWorker()
  self.dict = setmetatable({}, SimpleDict)
  ngx.shared.metrics = self.dict

  local p1 = require('prometheus').init("metrics")
  p1:init_worker(3)

  luaunit.assertEquals(#ngx.logs, 1)
  luaunit.assertStrContains(ngx.logs[1], "do not explicitly call init_worker")
end
function TestPrometheus.testErrorUnitialized()
  local p = require('prometheus')
  p:counter("metric1")
  p:histogram("metric2")
  p:gauge("metric3")
  p:metric_data()

  luaunit.assertEquals(#ngx.logs, 4)
end
function TestPrometheus.testErrorUnknownDict()
  local pok, perr = pcall(require('prometheus').init, "nonexistent")
  luaunit.assertEquals(pok, false)
  luaunit.assertStrContains(perr, "does not seem to exist")
end
function TestPrometheus:testErrorNoMemoryGaugeSet()
  local gauge3 = self.p:gauge("willnotfitk")
  self.counter1:inc(5)
  gauge3:set(111)

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 5)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)
  luaunit.assertEquals(sample(self.p, "willnotfitk"), 111)
  luaunit.assertEquals(#ngx.logs, 1)
end
function TestPrometheus:testErrorNoMemoryGaugeInc()
  local gauge3 = self.p:gauge("willnotfitk")
  self.counter1:inc(5)
  gauge3:inc(111)

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 5)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)
  luaunit.assertEquals(sample(self.p, "willnotfitk"), 111)
  luaunit.assertEquals(#ngx.logs, 1)
end
function TestPrometheus:testErrorNoMemoryCounter()
  local counter = self.p:counter("willnotfitk")
  self.counter1:inc(5)
  counter:inc(11)

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 5)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)
  luaunit.assertEquals(sample(self.p, "willnotfitk"), 11)
  luaunit.assertEquals(#ngx.logs, 1)
end
function TestPrometheus:testErrorInvalidMetricName()
  self.p:histogram("name with a space", "Histogram")
  self.p:gauge("nonprintable\004characters", "Gauge")
  self.p:counter("0startswithadigit", "Counter")
  self.p:counter("__ngx_prom__usesinternalprefix", "Counter no.2")

  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 4)
  luaunit.assertEquals(#ngx.logs, 4)
end
function TestPrometheus:testErrorInvalidLabels()
  self.p:histogram("hist1", "Histogram", {"le"})
  self.p:gauge("count1", "Gauge", {"le"})
  self.p:counter("count1", "Counter", {"foo\002"})

  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 3)
  luaunit.assertEquals(#ngx.logs, 3)
end
function TestPrometheus:testErrorInvalidBuckets()
  for _, boundary in ipairs({"1", true, {}}) do
    local ok, err = pcall(function()
      self.p:histogram("invalid_buckets", nil, nil, {boundary})
    end)
    luaunit.assertEquals(ok, false)
    luaunit.assertStrContains(err, "bucket boundaries should be numeric")
  end
end
function TestPrometheus:testErrorDuplicateMetrics()
  self.p:counter("metric1", "Another metric 1")
  self.p:counter("l1_count", "Conflicts with Histogram 1")
  self.p:counter("l2_sum", "Conflicts with Histogram 2")
  self.p:counter("l2_bucket", "Conflicts with Histogram 2")
  self.p:gauge("metric1", "Conflicts with Metric 1")
  self.p:histogram("l1", "Conflicts with Histogram 1")
  self.p:histogram("metric2", "Conflicts with Metric 2")
  self.p:counter("metric_A_count", "Metric ending with _count")
  self.p:histogram("metric_A", "Conflicts with metric_A_count")
  self.p:counter("metric_B_sum", "Metric ending with _sum")
  self.p:histogram("metric_B", "Conflicts with metric_B_sum")
  self.p:counter("metric_C_bucket", "Metric ending with _bucket")
  self.p:histogram("metric_C", "Conflicts with metric_C_bucket")
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 10)
  luaunit.assertEquals(#ngx.logs, 10)
end
function TestPrometheus:testErrorNegativeValue()
  self.counter1:inc(-5)

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)
  luaunit.assertEquals(#ngx.logs, 1)
end
function TestPrometheus:testErrorIncorrectLabels()
  self.counter1:inc(1, {"should-be-no-labels"})
  self.counter2:inc(1, {"too-few-labels"})
  self.counter2:inc(1, {nil, "v"})
  self.counter2:inc(1, {"v", nil})
  self.counter2:inc(1)
  self.counter3:inc(1, {nil})
  self.counter4:inc(1, {"one", nil, "three"})
  self.gauge1:set(1, {"should-be-no-labels"})
  self.gauge2:set(1, {"too-few-labels"})
  self.gauge2:set(1)
  self.hist2:observe(1, {"too", "many", "labels"})
  self.hist2:observe(1, {nil, "label"})
  self.hist2:observe(1, {"label", nil})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), nil)
  luaunit.assertEquals(sample(self.p, "l1_count"), nil)
  luaunit.assertEquals(sample(self.p, "gauge1"), nil)
  luaunit.assertEquals(sample(self.p, "gauge2"), nil)
  luaunit.assertEquals(sample(self.p, "l1_count"), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 13)
  luaunit.assertEquals(#ngx.logs, 13)
end
function TestPrometheus:testNumericLabelValues()
  self.counter2:inc(1, {0, 15.5})
  self.gauge2:set(1, {0, 15.5})
  self.hist2:observe(1, {-3, 90000})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'metric2{f2="0",f1="15.5"}'), 1)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="0",f1="15.5"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="-3",site="90000"}'), 1)
  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testMultibyteLabelValues()
  self.counter2:inc(1, {"foo", "baz\189\166qux"})
  self.counter2:inc(1, {"bad1\195\195bad", "bad2\224\161\209bad"})
  self.counter2:inc(1, {"bad3\240\144\129\192bad", "bad4\242\129\210bad"})
  self.counter2:inc(1, {"¢€𤭢", "Pay in €. Thanks."})
  self.gauge2:set(1, {"z\001", "\002"})
  self.gauge2:set(1, {"\224\143\175", "\237\129\128"})
  self.hist2:observe(1, {"\166omg", "fooшbar"})
  self.hist2:observe(1, {"\244\143\143\143", "\244"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'metric2{f2="foo",f1="baz"}'), 1)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="bad1",f1="bad2"}'), 1)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="bad3",f1="bad4"}'), 1)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="¢€𤭢",f1="Pay in €. Thanks."}'), 1)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="z\001",f1="\002"}'), 1)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="",f1="\237\129\128"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="",site="fooшbar"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="\244\143\143\143",site=""}'), 1)
  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testNoValues()
  self.counter1:inc()  -- defaults to 1
  self.gauge1:set()  -- should produce an error
  self.hist1:observe()  -- should produce an error

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 2)
  luaunit.assertEquals(#ngx.logs, 2)
end
function TestPrometheus:testCounters()
  self.counter1:inc()
  self.counter1:inc(4)
  self.counter2:inc(1, {"v2", "v1"})
  self.counter2:inc(3, {"v2", "v1"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 5)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="v1"}'), 4)
  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testGaugeSet()
  self.gauge1:set(100)
  luaunit.assertEquals(sample(self.p, "gauge1"), 100)
  self.gauge1:set(0)
  luaunit.assertEquals(sample(self.p, "gauge1"), 0)
  self.gauge1:set(-5)
  luaunit.assertEquals(sample(self.p, "gauge1"), -5)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)
end
function TestPrometheus:testGaugeIncDec()
  self.gauge1:inc(-1)
  luaunit.assertEquals(sample(self.p, "gauge1"), -1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge1:inc(3)
  luaunit.assertEquals(sample(self.p, "gauge1"), 2)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge1:inc()
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:inc(1, {"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:inc(5, {"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), 6)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="othervalue"}'), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:inc(-2, {"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), 4)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:inc(-5, {"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), -1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge1:inc(1, {"should-be-no-labels"})
  self.gauge2:inc(1, {"too-few-labels"})
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), -1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 2)
end
function TestPrometheus:testGaugeDel()
  self.gauge1:inc(1)
  luaunit.assertEquals(sample(self.p, "gauge1"), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge1:del()
  luaunit.assertEquals(sample(self.p, "gauge1"), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:inc(1, {"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:del({"f2value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)

  self.gauge2:del({"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)
end
function TestPrometheus:testCounterDel()
  self.counter1:inc(1)
  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.counter1:del()
  luaunit.assertEquals(sample(self.p, "metric1"), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.counter2:inc(1, {"f2value", "f1value"})
  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'metric2{f2="f2value",f1="f1value"}'), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.counter2:del()
  luaunit.assertEquals(sample(self.p, 'metric2{f2="f2value",f1="f1value"}'), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)

  self.counter2:del({"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'metric2{f2="f2value",f1="f1value"}'), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 1)
end
function TestPrometheus:testReset()
  self.gauge1:inc(1)
  luaunit.assertEquals(sample(self.p, "gauge1"), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge1:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, "gauge1"), nil)
  luaunit.assertEquals(self.gauge1.lookup, {})
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge1:inc(3)
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:inc(1, {"f2value", "f1value"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), 1)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:inc(4, {"f2value", "f1value2"})
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value2"}'), 4)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.gauge2:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), nil)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value2"}'), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.counter1:inc()
  self.counter1:inc(4)
  self.counter2:inc(1, {"v2", "v1"})
  self.counter2:inc(3, {"v2", "v2"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 5)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="v1"}'), 1)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="v2"}'), 3)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.counter1:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), nil)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="v1"}'), 1)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="v2"}'), 3)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.counter1:inc(4)
  self.p._counter:sync()
  self.counter2:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 4)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="v1"}'), nil)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="v2"}'), nil)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value"}'), nil)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="f2value",f1="f1value2"}'), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.hist1:observe(0.35)
  self.hist1:observe(0.4)
  self.hist2:observe(0.001, {"ok", "site1"})
  self.hist2:observe(0.15, {"ok", "site1"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 4)
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.3"}'), 0)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.4"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.5"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="+Inf"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_count'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_sum'), 0.75)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.005"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.1"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.2"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="+Inf"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_count{var="ok",site="site1"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="ok",site="site1"}'), 0.151)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.hist1:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 4)
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.4"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.5"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="+Inf"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l1_count'), nil)
  luaunit.assertEquals(sample(self.p, 'l1_sum'), nil)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.005"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.1"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.2"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="+Inf"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_count{var="ok",site="site1"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="ok",site="site1"}'), 0.151)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  self.hist1:observe(0.35)
  self.p._counter:sync()
  self.hist2:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, "metric1"), 4)
  luaunit.assertEquals(sample(self.p, "gauge1"), 3)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.4"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.5"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="+Inf"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l1_count'), 1)
  luaunit.assertEquals(sample(self.p, 'l1_sum'), 0.35)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.005"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.1"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.2"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="+Inf"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l2_count{var="ok",site="site1"}'), nil)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="ok",site="site1"}'), nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  -- Set a gauge value that will be reset by another worker.
  self.gauge1:set(42)
  self.gauge2:set(91, {"a", "b1"})
  self.gauge2:set(92, {"a", "b2"})
  luaunit.assertEquals(sample(self.p, "gauge1"), 42)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="a",f1="b1"}'), 91)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="a",f1="b2"}'), 92)
  luaunit.assertNotEquals(self.gauge1.lookup, {})
  luaunit.assertNotEquals(self.gauge2.lookup, {})
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  -- After another worker has reset the metric, confirm that the per-metric
  -- lookup table has been reset.
  self.gauge1_p2:reset()
  self.gauge2_p2:del({"a", "b1"})
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, "gauge1"), nil)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="a",f1="b1"}'), nil)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="a",f1="b2"}'), 92)
  luaunit.assertEquals(self.gauge1.lookup, {})
  luaunit.assertEquals(self.gauge2.lookup, {})
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)

  -- Similarly, check that a histogram metric reset by another worker
  -- results in metric lookup table being reset.
  self.hist1:reset()
  self.hist1:observe(0.44)
  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'l1_sum'), 0.44)
  luaunit.assertNotEquals(self.hist1.lookup, {})

  self.hist1_p2:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(sample(self.p, 'l1_sum'), nil)
  luaunit.assertEquals(self.hist1.lookup, {})
  luaunit.assertEquals(self.hist1_p2.lookup, {})

  -- Dictionary-failure checks inspect storage without triggering another scrape.
  self.gauge2:inc(4, {"key_not_exist", "key_not_exist"})
  self.gauge2:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(self.dict:get('gauge2{f2="key_not_exist",f1="key_not_exist"}'), nil)
  luaunit.assertEquals(self.dict:get("nginx_metric_errors_total"), 0)

  -- error get from dict
  self.gauge2:inc(4, {"dict_error", "dict_error"})
  self.gauge2:reset()
  self.p.key_index:sync()
  luaunit.assertEquals(self.dict:get('gauge2{f2="dict_error",f1="dict_error"}'), nil)
  luaunit.assertEquals(self.dict:get("nginx_metric_errors_total"), 1)
end
function TestPrometheus:testLatencyHistogram()
  self.hist1:observe(0.35)
  self.hist1:observe(0.4)
  self.hist2:observe(0.001, {"ok", "site1"})
  self.hist2:observe(0.15, {"ok", "site1"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.3"}'), 0)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.4"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.5"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="+Inf"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_count'), 2)
  luaunit.assertEquals(sample(self.p, 'l1_sum'), 0.75)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.005"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.1"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="0.2"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site1",le="+Inf"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_count{var="ok",site="site1"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="ok",site="site1"}'), 0.151)

  -- test observing a zero value
  self.hist1:observe(0)
  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.3"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.4"}'), 3)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.5"}'), 3)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="+Inf"}'), 3)
  luaunit.assertEquals(sample(self.p, 'l1_count'), 3)
  luaunit.assertEquals(sample(self.p, 'l1_sum'), 0.75)

  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(sample(self.p, "nginx_metric_errors_total"), 0)
end
function TestPrometheus:testLabelEscaping()
  self.counter2:inc(1, {"v2", "\""})
  self.counter2:inc(5, {"v2", "\\"})
  self.gauge2:set(1, {"v2", "\""})
  self.gauge2:set(5, {"v2", "\\"})
  self.gauge2:set(7, {"v3", "foo\nbar"})
  self.hist2:observe(0.001, {"ok", "site\"1"})
  self.hist2:observe(0.15, {"ok", "site\"1"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="\\""}'), 1)
  luaunit.assertEquals(sample(self.p, 'metric2{f2="v2",f1="\\\\"}'), 5)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="v2",f1="\\""}'), 1)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="v2",f1="\\\\"}'), 5)
  luaunit.assertEquals(sample(self.p, 'gauge2{f2="v3",f1="foo\\nbar"}'), 7)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site\\"1",le="0.005"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site\\"1",le="0.1"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site\\"1",le="0.2"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_bucket{var="ok",site="site\\"1",le="+Inf"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_count{var="ok",site="site\\"1"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l2_sum{var="ok",site="site\\"1"}'), 0.151)
  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testCustomBucketer1()
  local hist3 = self.p:histogram("l3", "Histogram 3", {"var"}, {1,2,3})
  self.hist1:observe(0.35)
  hist3:observe(2, {"ok"})
  hist3:observe(0.151, {"ok"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.3"}'), 0)
  luaunit.assertEquals(sample(self.p, 'l1_bucket{le="0.4"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="1"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="2"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="3"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="+Inf"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l3_count{var="ok"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l3_sum{var="ok"}'), 2.151)
  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testCustomBucketer2()
  local hist3 = self.p:histogram("l3", "Histogram 3", {"var"},
    {0.000005,5,50000})
  hist3:observe(0.000001, {"ok"})
  hist3:observe(3, {"ok"})
  hist3:observe(7, {"ok"})
  hist3:observe(70000, {"ok"})

  self.p._counter:sync()
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="5e-06"}'), 1)
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="5"}'), 2)
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="50000"}'), 3)
  luaunit.assertEquals(sample(self.p, 'l3_bucket{var="ok",le="+Inf"}'), 4)
  luaunit.assertEquals(sample(self.p, 'l3_count{var="ok"}'), 4)
  luaunit.assertEquals(sample(self.p, 'l3_sum{var="ok"}'), 70010.000001)
  luaunit.assertEquals(ngx.logs, nil)
end
function TestPrometheus:testHistogramBoundaryPrecision()
  local histogram = self.p:histogram("precision", nil, nil,
    {0.0000001, 0.123456789, 1})
  histogram:observe(0.00000005)
  histogram:observe(0.12)
  local values = samples(self.p)
  luaunit.assertEquals(values['precision_bucket{le="1e-07"}'], 1)
  luaunit.assertEquals(values['precision_bucket{le="0.123456789"}'], 2)
  luaunit.assertEquals(values['precision_bucket{le="0"}'], nil)
  luaunit.assertEquals(values['precision_bucket{le="+Inf"}'], 2)
  luaunit.assertEquals(values.precision_count, 2)
end

function TestPrometheus:testScalarHistogramSuffixes()
  self.gauge1:set(9)
  for _, suffix in ipairs({"_bucket", "_count", "_sum"}) do
    local name = "scalar" .. suffix
    local gauge = self.p:gauge(name, "Scalar metric", {"site"})
    gauge:set(2, {"le=west"})
    gauge:set(3, {"zeta"})
    local output = table.concat(self.p:metric_data())
    luaunit.assertStrContains(output, "# HELP " .. name .. " Scalar metric\n")
    luaunit.assertStrContains(output, "# TYPE " .. name .. " gauge\n")
    local type_idx = assert(output:find("# TYPE " .. name .. " gauge\n", 1, true))
    local sample_idx = assert(output:find(name .. '{site="le=west"} 2\n', 1, true))
    luaunit.assertEquals(type_idx < sample_idx, true)
    luaunit.assertEquals(sample(self.p, name .. '{site="le=west"}'), 2)
    gauge:reset()
    luaunit.assertEquals(sample(self.p, name .. '{site="le=west"}'), nil)
    luaunit.assertEquals(sample(self.p, name .. '{site="zeta"}'), nil)
  end
  luaunit.assertEquals(sample(self.p, "gauge1"), 9)
end

function TestPrometheus:testHistogramConcurrentFlush()
  local histogram = self.p:histogram("race", nil, nil, {1, 10, 100})
  histogram:observe(0.5)
  self.p._counter:sync()
  local before = {}
  for key, value in pairs(self.dict.dict) do before[key] = value end

  -- Prepare another worker's real counter flush without relying on the
  -- histogram's internal key format. Library instances in this test process
  -- normally share a worker-local increment buffer, so give it its own.
  histogram:observe(0.5)
  self.p._counter:sync()
  local increments = {}
  for key, value in pairs(self.dict.dict) do
    if type(value) == "number" and value ~= before[key] then
      increments[key] = value - (before[key] or 0)
    end
  end
  self.dict.dict = before
  local writer = setmetatable({
    dict = self.dict, increments = increments,
    error_metric_name = self.p.error_metric_name,
  }, getmetatable(self.p._counter))

  local flushed = false
  self.dict.get = function(dict, key)
    local value, err = SimpleDict.get(dict, key)
    if not flushed and increments[key] then
      flushed = true
      writer:sync()
    end
    return value, err
  end
  local raced = samples(self.p)
  luaunit.assertEquals(flushed, true)
  -- Both observations are fast. A flush between bucket reads must not
  -- manufacture observations in a slower range.
  luaunit.assertEquals(raced['race_bucket{le="10"}'] -
    raced['race_bucket{le="1"}'], 0)
  luaunit.assertEquals(raced['race_bucket{le="+Inf"}'] -
    raced['race_bucket{le="100"}'], 0)
  luaunit.assertEquals(raced.race_count, raced['race_bucket{le="+Inf"}'])
  luaunit.assertEquals(sample(self.p, 'race_bucket{le="1"}'), 2)
end

function TestPrometheus:testHistogramCompleteBuckets()
  local short = self.p:histogram("short", nil, nil, {1, 2})
  local extended = self.p:histogram("extended", nil, nil, {1, 2, 100, 10000})
  short:observe(1.5)
  extended:observe(1.5)
  local values = samples(self.p)
  for _, name in ipairs({"short", "extended"}) do
    luaunit.assertEquals(values[name .. '_bucket{le="1"}'], 0)
    luaunit.assertEquals(values[name .. '_bucket{le="2"}'], 1)
    luaunit.assertEquals(values[name .. '_bucket{le="+Inf"}'], 1)
    luaunit.assertEquals(values[name .. '_count'], 1)
  end
  -- Adding unused upper bounds must not create any new slow observations.
  luaunit.assertEquals(values['extended_bucket{le="100"}'], 1)
  luaunit.assertEquals(values['extended_bucket{le="10000"}'], 1)
end

function TestPrometheus:testHistogramRangesAndOverflow()
  local histogram = self.p:histogram("ranges", nil, nil, {1, 10, 100})
  for _, value in ipairs({0.5, 1, 2, 10, 100, 101}) do
    histogram:observe(value)
  end
  local values = samples(self.p)
  luaunit.assertEquals(values['ranges_bucket{le="1"}'], 2)
  luaunit.assertEquals(values['ranges_bucket{le="10"}'], 4)
  luaunit.assertEquals(values['ranges_bucket{le="100"}'], 5)
  luaunit.assertEquals(values['ranges_bucket{le="+Inf"}'], 6)
  luaunit.assertEquals(values.ranges_count, 6)
  luaunit.assertEquals(values.ranges_sum, 214.5)
end

function TestPrometheus:testHistogramBucketLayoutIsolation()
  local old = self.p:histogram("layout", nil, nil, {1, 10, 100})
  local new = self.p2:histogram("layout", nil, nil, {1, 2, 100})
  old:observe(5)
  self.p._counter:sync()
  new:observe(0.5)
  new:observe(3)
  local values = samples(self.p2)
  luaunit.assertEquals(values.layout_count, 2)
  luaunit.assertEquals(values.layout_sum, 3.5)
  luaunit.assertEquals(values['layout_bucket{le="2"}'], 1)
  local previous = samples(self.p)
  luaunit.assertEquals(previous.layout_count, 1)
  luaunit.assertEquals(previous.layout_sum, 5)
  luaunit.assertEquals(previous['layout_bucket{le="10"}'], 1)
end

function TestPrometheus:testHistogramPreciseBucketLayoutIsolation()
  local first_bound, second_bound = 0.3, 0.1 + 0.2
  luaunit.assertNotEquals(first_bound, second_bound)
  local old = self.p:histogram("precise", nil, nil, {first_bound, 1})
  local new = self.p2:histogram("precise", nil, nil, {second_bound, 1})
  old:observe(0.1)
  self.p._counter:sync()
  new:observe(0.2)

  local values = samples(self.p2)
  luaunit.assertEquals(values.precise_count, 1)
  luaunit.assertEquals(values.precise_sum, 0.2)
  local previous = samples(self.p)
  luaunit.assertEquals(previous.precise_count, 1)
  luaunit.assertEquals(previous.precise_sum, 0.1)
end

function TestPrometheus:testHistogramLegacyStorageIsolation()
  -- Simulate cumulative histogram cells left by an older library version.
  for key, value in pairs({
    ['legacy_bucket{le="001.0"}'] = 0,
    ['legacy_bucket{le="010.0"}'] = 100,
    ['legacy_bucket{le="100.0"}'] = 100,
    ['legacy_bucket{le="Inf"}'] = 100,
    legacy_count = 100, legacy_sum = 500,
  }) do
    self.dict:set(key, value)
    self.p.key_index:add(key)
  end
  local histogram = self.p:histogram("legacy", nil, nil, {1, 10, 100})
  histogram:observe(0.5)
  local values = samples(self.p)
  luaunit.assertEquals(values.legacy_count, 1)
  luaunit.assertEquals(values.legacy_sum, 0.5)
  luaunit.assertEquals(values['legacy_bucket{le="1"}'], 1)
  luaunit.assertEquals(values['legacy_bucket{le="+Inf"}'], 1)
end

function TestPrometheus:testHistogramLabelsAfterReload()
  for _, labeled_first in ipairs({false, true}) do
    local name = labeled_first and "labeled_first" or "plain_first"
    local label_names = {"site"}
    local label_values = {'a"b\\c\nd'}
    local old = self.p:histogram(name, nil,
      labeled_first and label_names or nil, {1, 10})
    local new = self.p2:histogram(name, nil,
      not labeled_first and label_names or nil, {1, 10})
    old:observe(0.5, labeled_first and label_values or nil)
    self.p._counter:sync()
    new:observe(0.5, not labeled_first and label_values or nil)
    local values = samples(self.p2)
    local labels = '{site="a\\"b\\\\c\\nd"}'
    luaunit.assertEquals(values[name .. '_count'], 1)
    luaunit.assertEquals(values[name .. '_count' .. labels], 1)
    luaunit.assertEquals(values[name .. '_bucket{le="1"}'], 1)
    luaunit.assertEquals(values[name .. '_bucket' ..
      labels:sub(1, -2) .. ',le="1"}'], 1)
    luaunit.assertEquals(values[name .. '_sum' .. labels], 0.5)
  end
end

function TestPrometheus:testCollect()
  local hist3 = self.p:histogram("b1", "Bytes", {"var", "stale"}, {0.1, 100, 2000})
  local hist4 = self.p:histogram("b2", "Labels", {}, {100, 2000})
  self.counter1:inc(5)
  self.counter2:inc(2, {"v2", "v1"})
  self.counter2:inc(2, {"v2", "v1"})
  self.gauge1:set(3)
  self.gauge2:set(2, {"v2", "v1"})
  self.gauge2:set(5, {"v2", "v1"})
  self.hist1:observe(0.000001)
  self.hist2:observe(0.000001, {"ok", "site2"})
  self.hist2:observe(3, {"ok", "site2"})
  self.hist2:observe(7, {"ok", "site2"})
  self.hist2:observe(70000, {"ok","site2"})
  hist3:observe(0.01, {"ok", "true"})
  hist3:observe(50, {"ok", "true"})
  hist3:observe(50, {"ok", "true"})
  hist3:observe(150, {"ok", "true"})
  hist3:observe(5000, {"ok", "true"})
  hist4:observe(50, {})
  hist4:observe(50, {})
  hist4:observe(150, {})
  hist4:observe(5000, {})
  self.p:collect()

  assert(find_idx(ngx.printed, "# HELP metric1 Metric 1") ~= nil)
  assert(find_idx(ngx.printed, "# TYPE metric1 counter") ~= nil)
  assert(find_idx(ngx.printed, "metric1 5") ~= nil)

  assert(find_idx(ngx.printed, "# TYPE metric2 counter") ~= nil)
  assert(find_idx(ngx.printed, 'metric2{f2="v2",f1="v1"} 4') ~= nil)

  assert(find_idx(ngx.printed, "# TYPE gauge1 gauge") ~= nil)
  assert(find_idx(ngx.printed, 'gauge1 3') ~= nil)

  assert(find_idx(ngx.printed, "# TYPE gauge2 gauge") ~= nil)
  assert(find_idx(ngx.printed, 'gauge2{f2="v2",f1="v1"} 5') ~= nil)

  assert(find_idx(ngx.printed, "# TYPE b1 histogram") ~= nil)
  assert(find_idx(ngx.printed, "# HELP b1 Bytes") ~= nil)
  assert(find_idx(ngx.printed, 'b1_bucket{var="ok",stale="true",le="0.1"} 1') ~= nil)
  assert(find_idx(ngx.printed, 'b1_bucket{var="ok",stale="true",le="100"} 3') ~= nil)
  assert(find_idx(ngx.printed, 'b1_sum{var="ok",stale="true"} 5250.01') ~= nil)
  assert(find_idx(ngx.printed, 'b2_bucket{le="100"} 2') ~= nil)
  assert(find_idx(ngx.printed, 'b2_sum{} 5250') ~= nil)

  assert(find_idx(ngx.printed, 'l2_bucket{var="ok",site="site2",le="4"} 2') ~= nil)
  assert(find_idx(ngx.printed, 'l2_bucket{var="ok",site="site2",le="+Inf"} 4') ~= nil)

  -- check that type comment exists and is before any samples for the metric.
  local type_idx = find_idx(ngx.printed, '# TYPE l1 histogram')
  assert (type_idx ~= nil)
  assert (ngx.printed[type_idx-1]:find("^l1") == nil)
  assert (ngx.printed[type_idx+1]:find("^l1") ~= nil)
  luaunit.assertEquals(ngx.logs, nil)
end

function TestPrometheus:testCollectWithPrefix()
  self.dict = setmetatable({}, SimpleDict)
  ngx.shared.metrics = self.dict
  local p = require('prometheus').init("metrics", "test_pref_")

  local counter1 = p:counter("metric1", "Metric 1")
  local gauge1 = p:gauge("gauge1", "Gauge 1")
  local hist1 = p:histogram("b1", "Bytes", {"var"}, {100, 2000})
  counter1:inc(5)
  gauge1:set(3)
  hist1:observe(50, {"ok"})
  hist1:observe(50, {"ok"})
  hist1:observe(150, {"ok"})
  hist1:observe(5000, {"ok"})
  p:collect()

  assert(find_idx(ngx.printed, "# HELP test_pref_metric1 Metric 1") ~= nil)
  assert(find_idx(ngx.printed, "# TYPE test_pref_metric1 counter") ~= nil)
  assert(find_idx(ngx.printed, "test_pref_metric1 5") ~= nil)

  assert(find_idx(ngx.printed, "# HELP test_pref_gauge1 Gauge 1") ~= nil)
  assert(find_idx(ngx.printed, "# TYPE test_pref_gauge1 gauge") ~= nil)
  assert(find_idx(ngx.printed, "test_pref_gauge1 3") ~= nil)

  assert(find_idx(ngx.printed, "# TYPE test_pref_b1 histogram") ~= nil)
  assert(find_idx(ngx.printed, "# HELP test_pref_b1 Bytes") ~= nil)
  assert(find_idx(ngx.printed, 'test_pref_b1_bucket{var="ok",le="100"} 2') ~= nil)
  assert(find_idx(ngx.printed, 'test_pref_b1_sum{var="ok"} 5250') ~= nil)
end

TestKeyIndex = {}
function TestKeyIndex:setUp()
  self.dict = setmetatable({}, SimpleDict)
  ngx.shared.metrics = self.dict
  self.key_index = require('prometheus_keys').new(self.dict, '_prefix_', function(key)
    self.last_deleted_key = key
  end)
end
function TestKeyIndex.tearDown()
  ngx.logs = nil
end
function TestKeyIndex.testInit()
  luaunit.assertEquals(ngx.logs, nil)
end
function TestKeyIndex:testAdd()
  self.key_index:add("single", "eviction_err")
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(self.dict:get("_prefix_key_count"), 1)
  luaunit.assertEquals(self.dict:get("_prefix_key_1"), "single")

  self.key_index:add({"multiple", "keys"}, "eviction_err")
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(self.dict:get("_prefix_key_count"), 3)
  luaunit.assertEquals(self.dict:get("_prefix_key_2"), "multiple")
  luaunit.assertEquals(self.dict:get("_prefix_key_3"), "keys")

  -- adding already existing key should do nothing
  self.key_index:add("single", "eviction_err")
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(self.dict:get("_prefix_key_count"), 3)

  -- error should be returned when memory is full
  local err = self.key_index:add("willnotfitv", "eviction_err")
  luaunit.assertEquals(err,
    "eviction_err; key index: add key: idx=_prefix_key_4, key=willnotfitv")
  luaunit.assertEquals(self.dict:get("_prefix_key_count"), 4)
end
function TestKeyIndex:testRemove()
  self.key_index:add({"key1", "key2", "key3"}, "eviction_err")

  self.key_index:remove("key2")
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(self.dict:get("_prefix_key_count"), 3)
  luaunit.assertEquals(self.dict:get("_prefix_delete_count"), 1)
  local keys = self.key_index:list()
  luaunit.assertEquals(#keys, 2)
  luaunit.assertEquals(keys[1], "key1")
  luaunit.assertEquals(keys[2], "key3")

  self.key_index:remove("key4")
  luaunit.assertEquals(#ngx.logs, 1)
  keys = self.key_index:list()
  luaunit.assertEquals(#keys, 2)
  luaunit.assertEquals(keys[1], "key1")
  luaunit.assertEquals(keys[2], "key3")
end
function TestKeyIndex:testList()
  self.key_index:add({"key1", "key2", "key3"}, "eviction_err")
  local keys = self.key_index:list()
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(#keys, 3)
  luaunit.assertEquals(keys[1], "key1")
  luaunit.assertEquals(keys[2], "key2")
  luaunit.assertEquals(keys[3], "key3")
end

function TestKeyIndex:testSync()
  self.key_index:sync()
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(self.dict:get("_prefix_key_count"), nil)
  luaunit.assertEquals(self.dict:get("_prefix_delete_count"), nil)

  -- key added by another worker
  self.dict:set("_prefix_key_count", 1)
  self.dict:set("_prefix_key_1", "key1")
  self.key_index:sync()
  local keys = self.key_index:list()
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(#keys, 1)
  luaunit.assertEquals(keys[1], "key1")

  -- multiple keys added by another worker
  self.dict:set("_prefix_key_count", 3)
  self.dict:set("_prefix_key_2", "key2")
  self.dict:set("_prefix_key_3", "key3")
  self.key_index:sync()
  keys = self.key_index:list()
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(#keys, 3)
  luaunit.assertEquals(keys[1], "key1")
  luaunit.assertEquals(keys[2], "key2")
  luaunit.assertEquals(keys[3], "key3")

  -- key deleted by another worker
  self.dict:set("_prefix_delete_count", 1)
  self.dict:delete("_prefix_key_2")
  self.key_index:sync()
  keys = self.key_index:list()
  luaunit.assertEquals(ngx.logs, nil)
  luaunit.assertEquals(#keys, 2)
  luaunit.assertEquals(keys[1], "key1")
  luaunit.assertEquals(keys[2], "key3")
  luaunit.assertEquals(self.last_deleted_key, "key2")
end

function TestPrometheus.testPrintfTable()
  local p = require('prometheus')
  luaunit.assertEquals(p._table_to_string(nil), "nil")
  luaunit.assertEquals(p._table_to_string({}), "<>")
  luaunit.assertEquals(p._table_to_string({"foo"}), "<foo>")
  luaunit.assertEquals(p._table_to_string({"foo",2,"bar"}), "<foo,2,bar>")
  -- table ends at the first value before nil.
  luaunit.assertEquals(p._table_to_string({nil,2,nil,"foo",nil}), "<nil,2>")
end

os.exit(luaunit.run())
