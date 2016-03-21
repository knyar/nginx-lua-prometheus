# Nginx exporter for Prometheus

This is a Lua module that can be used with Nginx to keep track of metrics and
expose them on a separate web page that can be scraped by
[prometheus](https://prometheus.io).

## Quick start guide

You would need to install nginx package with lua support (`nginx-extras` on
Debian) and make `prometheus.lua` available in your `LUA_PATH` (or just point
`lua_package_path` to a directory with this git repo).

To initialize the module, add the following to your `nginx.conf`. On Debian
a separate file in `/etc/nginx/conf.d` is usually the right place for this:

```
lua_shared_dict prometheus_metrics 10M;
lua_package_path "/path/to/nginx_exporter/?.lua";
init_by_lua 'prometheus = require("prometheus").init("prometheus_metrics")';
```

This configures a shared dictionary for your metrics called
`prometheus_metrics` with a 10MB size limit and instructs the module to use it.

Next, add the following for each server which needs to export metrics:

```
log_by_lua 'prometheus:measure()';
```

This can also be set per location, or globally if you want to track all
requests.

Last step is to configure a separate server that will expose the metrics.
Please make sure to only make it reachable from your Prometheus server:

```
server {
  listen 9145;
  allow 192.168.0.0/16;
  deny all;
  location /metrics {
    content_by_lua 'prometheus:collect()';
  }
}
```

Metrics will be available at `http://your.nginx:9145/metrics`.

## Exported metrics

* `nginx_http_requests_total` - number of HTTP requests, grouped by status;
* `nginx_http_request_duration_seconds` - latency histogram of requests in
   seconds;
* `nginx_metric_errors_total` - number of internal errors.

The module increments the `nginx_metric_errors_total` metric if it encounters
an error (for example, when `lua_shared_dict` becomes full). You might want
to configure an alert on that metric.

### Using labels

You can pass a lua table as an argument to `prometheus:measure()` to
set metric labels. For example:

```
log_by_lua 'prometheus:measure({site="mywebpage"})';
```

You can use this to group requests by HTTP host automatically:

```
log_by_lua 'prometheus:measure({host=ngx.var.host:gsub("^www.", "")})';
```

### Latency buckets

By default latency measurements get distributed into 20 latency buckets covering
a range from 5ms to 10s. You can override default latency bucket list using the
second argument to `init()`, which accepts a table mapping bucketer name to an
array of bucket boundaries. By default distributions use a bucketer called
`latency`. For example, to use 4 buckets only (less or equal to 50ms, 100ms,
500ms, or more than 500ms):

```
init_by_lua 'prometheus = require("prometheus").init(
  "prometheus_metrics", {latency={0.05, 0.1, 0.5}})';
```

## Custom metrics

You can track any other metric in the `log_by_lua` section. For example, to add
a counter tracking total size of incoming requests:

```
log_by_lua 'prometheus:inc(
  "nginx_http_request_size_bytes", nil,
  tonumber(ngx.var.request_length))`;
```

You can use the second argument to provide metric labels:

```
log_by_lua 'prometheus:inc(
  "nginx_http_request_size_bytes", {site="website1"},
  tonumber(ngx.var.request_length))`;
```

### Distributions

You can add custom distributions as well. For example, to keep track of
response sizes, you would need to define a custom bucketer first (default
latency bucketer is not suitable for byte sizes):

```
init_by_lua 'prometheus = require("prometheus").init("prometheus_metrics",
  {bytes={10,100,1000,10000,100000,1000000}})';
```

Then you can use the new `bytes` bucketer in a distribution metric:

```
log_by_lua 'prometheus:histogram_observe("nginx_http_response_size_bytes", nil,
  tonumber(ngx.var.bytes_sent), "bytes")';
```

## Development

### Install dependencies for testing

- `luarocks install luacheck`
- `luarocks install luaunit`

### Run tests

- `luacheck --globals ngx -- prometheus.lua`
- `lua prometheus_test.lua`

## License

Licensed under MIT license.
