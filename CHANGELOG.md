# Changelog

This file only calls out major changes. Please see [the list of Git commits](
https://github.com/knyar/nginx-lua-prometheus/commits/master) for the full list
of changes.

## 0.20201218

Histogram metrics can now be reset (#112).

## 0.20201118

Allow utf8 label values (#110).

## 0.20200523

- Scalability improvements that allow tracking a larger number of metrics
  without impacting nginx performance (#82).
- Simplified library initialization, moving all of it to `init_worker_by_lua_block`.
- Error metric name is now configurable (#91).

## 0.20200420

This is a significant release that includes counter performance improvements.

**BREAKING CHANGE**: this release requires additional per-worker initialization
in the `init_worker_by_lua_block` section of nginx configuration.

- Added support for incrementing and decrementing gauges (#52).
- Added del and reset for gauge and counter metrics (#56).
- Added per-worker lua counters that allow incrementing counter metrics
  without locking the dictionary (#75).

## 0.20181120

Added stream module support (#42).

## 0.20171117

Improved performance of metric collection (#25).

## 0.1-20170610

Initial version of the library.
