#!/bin/bash

set -x -e -u -o pipefail

base_dir="$(cd "$(dirname "$0")"; pwd -P)"
container_name="nginx_lua_prometheus_integration_test_nginx"
image_name="${container_name}_image"

docker build -t ${image_name} ${base_dir}

function cleanup {
  docker rm -f ${container_name} || true
}
cleanup
trap cleanup EXIT

#docker run --name ${container_name} -p 18001:18001 -p 18002:18002 \
docker run -d --name ${container_name} -p 18001:18001 -p 18002:18002 \
  -v ${base_dir}/../:/nginx-lua-prometheus ${image_name} \
  nginx -c /nginx-lua-prometheus/integration/nginx.conf

go run test.go