package = "nginx-lua-prometheus"
version = "0.20260121-1"

source = {
  url = "git+https://github.com/solidwall/nginx-lua-prometheus.git",
}

description = {
  summary = "Prometheus metric library for Nginx",
  homepage = "https://github.com/solidwall/nginx-lua-prometheus",
}

dependencies = {
  "lua >= 5.1",
  "lua-resty-lock",
}

build = {
    type = "builtin",
    modules = {
        ["prometheus"] = "prometheus.lua",
        ["prometheus_keys"] = 'prometheus_keys.lua',
        ["prometheus_resty_counter"] = 'prometheus_resty_counter.lua',
    }
}
