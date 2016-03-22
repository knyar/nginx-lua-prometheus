# Prometheus metric library for Nginx

This is a Lua library that can be used with Nginx to keep track of metrics and
expose them on a separate web page to be pulled by
[Prometheus](https://prometheus.io).

## Quick start guide

You would need to install nginx package with lua support (`nginx-extras` on
Debian) and make `prometheus.lua` available in your `LUA_PATH` (or just point
`lua_package_path` to a directory with this git repo).

To track request latency broken down by HTTP host and request count broken
down by host and status, add the following to `nginx.conf`:

```
lua_shared_dict prometheus_metrics 10M;
lua_package_path "/path/to/nginx-lua-prometheus/?.lua";
init_by_lua '
  prometheus = require("prometheus").init("prometheus_metrics")
  metric_requests = prometheus:counter(
    "nginx_http_requests_total", "Number of HTTP requests", {"host", "status"})
  metric_latency = prometheus:histogram(
    "nginx_http_request_duration_seconds", "HTTP request latency", {"host"})
';
log_by_lua '
  local host = ngx.var.host:gsub("^www.", "")
  metric_requests:inc(1, {host, ngx.var.status})
  metric_latency:observe(ngx.now() - ngx.req.start_time(), {host})
';
```

This:
* configures a shared dictionary for your metrics called `prometheus_metrics`
  with a 10MB size limit;
* registers a counter called `nginx_http_requests_total` with two labels:
  `host` and `status`;
* registers a histogram called `nginx_http_request_duration_seconds` with one
  label `host`;
* on each HTTP request measures its latency, recording it in the histogram and
  increments the counter, setting current HTTP host as `host` label and
  HTTP status code as `status` label.

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

## API reference

### Built-in metrics

The module increments the `nginx_metric_errors_total` metric if it encounters
an error (for example, when `lua_shared_dict` becomes full). You might want
to configure an alert on that metric.

## Development

### Install dependencies for testing

- `luarocks install luacheck`
- `luarocks install luaunit`

### Run tests

- `luacheck --globals ngx -- prometheus.lua`
- `lua prometheus_test.lua`

## License

Licensed under MIT license.
