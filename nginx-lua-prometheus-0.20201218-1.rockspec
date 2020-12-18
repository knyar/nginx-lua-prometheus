-- Note, this file must have version in its name
-- (see https://github.com/knyar/nginx-lua-prometheus/issues/27)
package = "nginx-lua-prometheus"
version = "0.20201218-1"

source = {
  url = "git://github.com/knyar/nginx-lua-prometheus.git",
  tag = "0.20201218",
}

description = {
  summary = "Prometheus metric library for Nginx",
  homepage = "https://github.com/knyar/nginx-lua-prometheus",
  license = "MIT",
}

dependencies = {
  "lua >= 5.1",
}

build = {
    type = "builtin",
    modules = {
        ["prometheus"] = "prometheus.lua",
        ["prometheus_keys"] = 'prometheus_keys.lua',
        ["prometheus_resty_counter"] = 'prometheus_resty_counter.lua',
    }
}
