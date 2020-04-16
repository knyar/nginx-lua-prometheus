This is a simple integration test for nginx-lua-prometheus.

The test builds and starts an nginx container with nginx-lua-prometheus.
Then a small Go program starts several concurrent HTTP clients sending
requests to nginx in a loop for a predefined amount of time. After all requests
are sent, the test collects metrics and compares request counters with the
total number of requests sent by clients. A few other metric checks are
performed as well.
