-- Note, this file must have version in its name
-- (see https://github.com/knyar/nginx-lua-prometheus/issues/27)
package = "nginx-lua-prometheus"
version = "0.20171117-4"

source = {
  url = "git://github.com/knyar/nginx-lua-prometheus.git"
}

description = {
  summary = "Prometheus metric library for Nginx",
  homepage = "https://github.com/knyar/nginx-lua-prometheus",
  license = "MIT"
}

dependencies = {
  "lua >= 5.1",
}

build = {
    type = "builtin",
    modules = {
        ["nginx.prometheus"] = "prometheus.lua"
    }
}
