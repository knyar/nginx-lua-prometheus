[![Build Status](https://secure.travis-ci.org/knyar/nginx-lua-prometheus.svg?branch=master)](http://travis-ci.org/knyar/nginx-lua-prometheus?branch=master)
[![Coverage Status](https://coveralls.io/repos/github/knyar/nginx-lua-prometheus/badge.svg?branch=master)](https://coveralls.io/github/knyar/nginx-lua-prometheus?branch=master)

# Prometheus metric library for Nginx

This is a Lua library that can be used with Nginx to keep track of metrics and
expose them on a separate web page to be pulled by
[Prometheus](https://prometheus.io).

## Installation

You need to install nginx package with lua support (`libnginx-mod-http-lua` on
newer Debian versions, or `nginx-extras` on older ones). The library file,
`prometheus.lua`, needs to be available in `LUA_PATH`. If this is the only Lua
library you use, you can just point `lua_package_path` to the directory with
this git repo checked out (see example below).

OpenResty users will find this library in [opm](https://opm.openresty.org/). It
is also available via
[luarocks](https://luarocks.org/modules/knyar/nginx-lua-prometheus).

## Quick start guide

To track request latency broken down by server name and request count
broken down by server name and status, add the following to the `http` section
of `nginx.conf`:

```
lua_shared_dict prometheus_metrics 10M;
lua_package_path "/path/to/nginx-lua-prometheus/?.lua;;";
init_worker_by_lua_block {
  prometheus = require("prometheus").init("prometheus_metrics")
  metric_requests = prometheus:counter(
    "nginx_http_requests_total", "Number of HTTP requests", {"host", "status"})
  metric_latency = prometheus:histogram(
    "nginx_http_request_duration_seconds", "HTTP request latency", {"host"})
  metric_connections = prometheus:gauge(
    "nginx_http_connections", "Number of HTTP connections", {"state"})
}
log_by_lua_block {
  metric_requests:inc(1, {ngx.var.server_name, ngx.var.status})
  metric_latency:observe(tonumber(ngx.var.request_time), {ngx.var.server_name})
}
```

This:
* configures a shared dictionary for your metrics called `prometheus_metrics`
  with a 10MB size limit;
* registers a counter called `nginx_http_requests_total` with two labels:
  `host` and `status`;
* registers a histogram called `nginx_http_request_duration_seconds` with one
  label `host`;
* registers a gauge called `nginx_http_connections` with one label `state`;
* on each HTTP request measures its latency, recording it in the histogram and
  increments the counter, setting current server name as the `host` label and
  HTTP status code as the `status` label.

Last step is to configure a separate server that will expose the metrics.
Please make sure to only make it reachable from your Prometheus server:

```
server {
  listen 9145;
  allow 192.168.0.0/16;
  deny all;
  location /metrics {
    content_by_lua_block {
      metric_connections:set(ngx.var.connections_reading, {"reading"})
      metric_connections:set(ngx.var.connections_waiting, {"waiting"})
      metric_connections:set(ngx.var.connections_writing, {"writing"})
      prometheus:collect()
    }
  }
}
```

Metrics will be available at `http://your.nginx:9145/metrics`. Note that the
gauge metric in this example contains values obtained from nginx global state,
so they get set immediately before metrics are returned to the client.

## API reference

### init()

**syntax:** require("prometheus").init(*dict_name*, [*options*]])

Initializes the module. This should be called once from the
[init_worker_by_lua_block](https://github.com/openresty/lua-nginx-module#init_worker_by_lua_block)
section of nginx configuration.

* `dict_name` is the name of the nginx shared dictionary which will be used to
  store all metrics. Defaults to `prometheus_metrics` if not specified.
* `options` is a table of configuration options that can be provided. Accepted
  options are:
  * `prefix` (string): metric name prefix. This string will be prepended to
    metric names on output.
  * `error_metric_name` (string): Can be used to change the default name of
    error metric (see [Built-in metrics](#built-in-metrics) for details).
  * `sync_interval` (number): sets per-worker counter sync interval in seconds.
    This sets the boundary on eventual consistency of counter metrics. Defaults
    to 1.

Returns a `prometheus` object that should be used to register metrics.

Example:
```
init_worker_by_lua_block {
  prometheus = require("prometheus").init("prometheus_metrics", {sync_interval=3})
}
```

### prometheus:counter()

**syntax:** prometheus:counter(*name*, *description*, *label_names*)

Registers a counter. Should be called once for each counter from the
[init_worker_by_lua_block](
https://github.com/openresty/lua-nginx-module#init_worker_by_lua_block)
section.

* `name` is the name of the metric.
* `description` is the text description that will be presented to Prometheus
  along with the metric. Optional (pass `nil` if you still need to define
  label names).
* `label_names` is an array of label names for the metric. Optional.

[Naming section](https://prometheus.io/docs/practices/naming/) of Prometheus
documentation provides good guidelines on choosing metric and label names.

Returns a `counter` object that can later be incremented.

Example:
```
init_worker_by_lua_block {
  prometheus = require("prometheus").init("prometheus_metrics")
  metric_bytes = prometheus:counter(
    "nginx_http_request_size_bytes", "Total size of incoming requests")
  metric_requests = prometheus:counter(
    "nginx_http_requests_total", "Number of HTTP requests", {"host", "status"})
}
```

### prometheus:gauge()

**syntax:** prometheus:gauge(*name*, *description*, *label_names*)

Registers a gauge. Should be called once for each gauge from the
[init_worker_by_lua_block](
https://github.com/openresty/lua-nginx-module#init_worker_by_lua_block)
section.

* `name` is the name of the metric.
* `description` is the text description that will be presented to Prometheus
  along with the metric. Optional (pass `nil` if you still need to define
  label names).
* `label_names` is an array of label names for the metric. Optional.

Returns a `gauge` object that can later be set.

Example:
```
init_worker_by_lua_block {
  prometheus = require("prometheus").init("prometheus_metrics")
  metric_connections = prometheus:gauge(
    "nginx_http_connections", "Number of HTTP connections", {"state"})
}
```

### prometheus:histogram()

**syntax:** prometheus:histogram(*name*, *description*, *label_names*,
  *buckets*)

Registers a histogram. Should be called once for each histogram from the
[init_worker_by_lua_block](
https://github.com/openresty/lua-nginx-module#init_worker_by_lua_block)
section.

* `name` is the name of the metric.
* `description` is the text description. Optional.
* `label_names` is an array of label names for the metric. Optional.
* `buckets` is an array of numbers defining bucket boundaries. Optional,
  defaults to 20 latency buckets covering a range from 5ms to 10s (in seconds).

Returns a `histogram` object that can later be used to record samples.

Example:
```
init_worker_by_lua_block {
  prometheus = require("prometheus").init("prometheus_metrics")
  metric_latency = prometheus:histogram(
    "nginx_http_request_duration_seconds", "HTTP request latency", {"host"})
  metric_response_sizes = prometheus:histogram(
    "nginx_http_response_size_bytes", "Size of HTTP responses", nil,
    {10,100,1000,10000,100000,1000000})
}
```

### prometheus:collect()

**syntax:** prometheus:collect()

Presents all metrics in a text format compatible with Prometheus. This should be
called in
[content_by_lua_block](https://github.com/openresty/lua-nginx-module#content_by_lua_block)
to expose the metrics on a separate HTTP page.

Example:
```
location /metrics {
  content_by_lua_block { prometheus:collect() }
  allow 192.168.0.0/16;
  deny all;
}
```

### prometheus:metric_data()

**syntax:** prometheus:metric_data()

Returns metric data as an array of strings.

### counter:inc()

**syntax:** counter:inc(*value*, *label_values*)

Increments a previously registered counter. This is usually called from
[log_by_lua_block](https://github.com/openresty/lua-nginx-module#log_by_lua_block)
globally or per server/location.

* `value` is a value that should be added to the counter. Defaults to 1.
* `label_values` is an array of label values.

The number of label values should match the number of label names defined when
the counter was registered using `prometheus:counter()`. No label values should
be provided for counters with no labels. Non-printable characters will be
stripped from label values.

Example:
```
log_by_lua_block {
  metric_bytes:inc(tonumber(ngx.var.request_length))
  metric_requests:inc(1, {ngx.var.server_name, ngx.var.status})
}
```

### counter:del()

**syntax:** counter:del(*label_values*)

Delete a previously registered counter. This is usually called when you don't
need to observe such counter (or a metric with specific label values in this
counter) any more. If this counter has labels, you have to pass `label_values`
to delete the specific metric of this counter. If you want to delete all the
metrics of a counter with labels, you should call `Counter:reset()`.

* `label_values` is an array of label values.

The number of label values should match the number of label names defined when
the counter was registered using `prometheus:counter()`. No label values should
be provided for counters with no labels. Non-printable characters will be
stripped from label values.

This function will wait for `sync_interval` before deleting the metric to
allow all workers to sync their counters.

### counter:reset()

**syntax:** counter:reset()

Delete all metrics for a previously registered counter. If this counter have no
labels, it is just the same as `Counter:del()` function. If this counter have labels,
it will delete all the metrics with different label values.

This function will wait for `sync_interval` before deleting the metrics to
allow all workers to sync their counters.

### gauge:set()

**syntax:** gauge:set(*value*, *label_values*)

Sets the current value of a previously registered gauge. This could be called
from [log_by_lua_block](https://github.com/openresty/lua-nginx-module#log_by_lua_block)
globally or per server/location to modify a gauge on each request, or from
[content_by_lua_block](https://github.com/openresty/lua-nginx-module#content_by_lua_block)
just before `prometheus::collect()` to return a real-time value.

* `value` is a value that the gauge should be set to. Required.
* `label_values` is an array of label values.

### gauge:inc()

**syntax:** gauge:inc(*value*, *label_values*)

Increments or decrements a previously registered gauge. This is usually called
when you want to observe the real-time value of a metric that can both be
increased and decreased.

* `value` is a value that should be added to the gauge. It could be a negative
value when you need to decrease the value of the gauge. Defaults to 1.
* `label_values` is an array of label values.

The number of label values should match the number of label names defined when
the gauge was registered using `prometheus:gauge()`. No label values should
be provided for gauges with no labels. Non-printable characters will be
stripped from label values.

### gauge:del()

**syntax:** gauge:del(*label_values*)

Delete a previously registered gauge. This is usually called when you don't
need to observe such gauge (or a metric with specific label values in this
gauge) any more. If this gauge has labels, you have to pass `label_values`
to delete the specific metric of this gauge. If you want to delete all the
metrics of a gauge with labels, you should call `Gauge:reset()`.

* `label_values` is an array of label values.

The number of label values should match the number of label names defined when
the gauge was registered using `prometheus:gauge()`. No label values should
be provided for gauges with no labels. Non-printable characters will be
stripped from label values.

### gauge:reset()

**syntax:** gauge:reset()

Delete all metrics for a previously registered gauge. If this gauge have no
labels, it is just the same as `Gauge:del()` function. If this gauge have labels,
it will delete all the metrics with different label values.

### histogram:observe()

**syntax:** histogram:observe(*value*, *label_values*)

Records a value in a previously registered histogram. Usually called from
[log_by_lua_block](https://github.com/openresty/lua-nginx-module#log_by_lua_block)
globally or per server/location.

* `value` is a value that should be recorded. Required.
* `label_values` is an array of label values.

Example:
```
log_by_lua_block {
  metric_latency:observe(tonumber(ngx.var.request_time), {ngx.var.server_name})
  metric_response_sizes:observe(tonumber(ngx.var.bytes_sent))
}
```

### histogram:reset()

**syntax:** histogram:reset()

Delete all metrics for a previously registered histogram.

This function will wait for `sync_interval` before deleting the metrics to
allow all workers to sync their counters.

### Built-in metrics

The module increments an error metric called `nginx_metric_errors_total`
(unless another name was configured in [init()](#init)) if it encounters
an error (for example, when `lua_shared_dict` becomes full). You might want
to configure an alert on that metric.

## Caveats

### Usage in stream module

For now, there is no way to share a dictionary between HTTP and Stream modules
in Nginx. If you are using this library to collect metrics from stream module,
you will need to configure a separate endpoint to return them. Here's an
example.

```
server {
  listen 9145;
  content_by_lua_block {
    local sock = assert(ngx.req.socket(true))
    local data = sock:receive()
    local location = "GET /metrics"
    if string.sub(data, 1, string.len(location)) == location then
      ngx.say("HTTP/1.1 200 OK")
      ngx.say("Content-Type: text/plain")
      ngx.say("")
      ngx.say(table.concat(prometheus:metric_data(), ""))
    else
      ngx.say("HTTP/1.1 404 Not Found")
    end
  }
}
```

## Troubleshooting

### Make sure that nginx lua module is enabled

If you experience problems indicating that nginx doesn't know how to interpret
lua scripts, please make sure that [the lua
module](https://github.com/openresty/lua-nginx-module) is enabled. You might
need something like this in your `nginx.conf`:

    load_module modules/ndk_http_module.so;
    load_module modules/ngx_http_lua_module.so;

### Keep lua code cache enabled

This module expects the
[lua_code_cache](https://github.com/openresty/lua-nginx-module#lua_code_cache)
option to be `on` (which is the default).

### Try using an older version of the library

If you are seeing library initialization errors, followed by errors for each
metric change request (e.g. *attempt to index global '...' (a nil value)*),
you are probably using an old version of lua-nginx-module. For example, this
will happen if you try using the latest version of this library with the
`nginx-extras` package shipped with Ubuntu 16.04.

If you cannot upgrade nginx and lua-nginx-module, you can try using an older
version of this library; it will not have the latest performance optimizations,
but will still be functional. The recommended older release to use is
[0.20181120](https://github.com/knyar/nginx-lua-prometheus/tree/0.20181120).

## Development

### Install dependencies for testing

- `luarocks install luacheck`
- `luarocks install luaunit`

### Run tests

- `luacheck --globals ngx -- prometheus.lua`
- `lua prometheus_test.lua`
- `cd integration && ./test.sh` (requires Docker and Go)

### Releasing new version

- update CHANGELOG.md
- update version in the `dist.ini`
- rename `.rockspec` file and update version inside it
- commit changes
- create a new Git tag: `git tag 0.XXXXXXXX && git push origin 0.XXXXXXXX`
- push to luarocks: `luarocks upload nginx-lua-prometheus-0.20181120-1.rockspec`
- upload to OPM: `opm build && opm upload`

## Credits

- Created and maintained by Anton Tolchanov ([@knyar](https://github.com/knyar))
- Metrix prefix support contributed by david birdsong ([@davidbirdsong](
  https://github.com/davidbirdsong))
- Gauge support contributed by Cosmo Petrich ([@cosmopetrich](
  https://github.com/cosmopetrich))
- Performance improvements and per-worker counters are contributed by Wangchong
  Zhou ([@fffonion](https://github.com/fffonion)) / [@Kong](
  https://github.com/Kong).
- Metric name tracking improvements contributed by Jan Dolinár ([@dolik-rce](
  https://github.com/dolik-rce))

## License

Licensed under MIT license.

### Third Party License

Following third party modules are used in this library:

- [Kong/lua-resty-counter](https://github.com/Kong/lua-resty-counter)

This module is licensed under the Apache 2.0 license.

Copyright (C) 2019, Kong Inc.

All rights reserved.

