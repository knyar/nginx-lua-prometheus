# Changelog

This file only calls out major changes. Please see [the list of Git commits](
https://github.com/knyar/nginx-lua-prometheus/commits/master) for the full list
of changes.

## 0.20260912

- Fixed histogram inconsistencies during concurrent worker updates that could
  report observations in empty ranges or cause the `+Inf` bucket to differ from
  `_count`. Empty buckets are now always exposed (#179).
- Fixed a precision issue with histogram bucket labels. Now full floating-point
  precision is preserved using a compact decimal representation.
- Changed histogram storage to support these fixes. Existing histogram values
  were not migrated, so upgrading resets histogram series.
- Improved bucket boundary validation. NaN, infinite, unsorted, or duplicate
  histogram bucket boundaries are now rejected during registration (#180).
- Added a warning when multiple Prometheus instances are using the same shared
  dictionary in one worker.

Please restart nginx or use a fresh shared dictionary when upgrading or
changing histogram bucket boundaries. A graceful reload retains old storage and
can temporarily expose both old and new histogram series while workers overlap.

## 0.20240525

- Fixed a bug that prevented usage of metrics that had previously been reset
  (#171).
- Removed the size limit for per-metric lookup tables, instead resetting the
  lookup tables every time a metric is reset.
- Reordered the way histogram counters are incremented to partially mitigate
  consistency issues (#161).

## 0.20230607

Improved checking of label values.

## 0.20221218

- Added escaping of newline characters in label values (#145).
- Improved detection of LRU evictions (#147, #148).
- Per-worker metric name lookup tables now have a bounded size aimed at preventing
  memory leaking in environments with high metric churn (#151).

## 0.20220527

Performance optimization aimed at decreasing impact that metric collection has
on other requests (#139).

## 0.20220127

Performance optimization of metric collection (#131).

## 0.20210206

Bucket label values no longer have leading and trailing zeroes (#119).

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
