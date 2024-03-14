#!/bin/bash

set -x -e -u -o pipefail

base_dir="$(cd "$(dirname "$0")"; pwd -P)"
container_name="nginx_lua_prometheus_integration_test_nginx"
image_name="${container_name}_image"

cd "${base_dir}"

docker build -t ${image_name} .

function nginx_logs {
  docker logs ${container_name} || true
  # Debian has nginx compiled with --error-log-path=/var/log/nginx/error.log
  # so some early messages might be logged there.
  docker exec ${container_name} cat /var/log/nginx/error.log || true
}

function cleanup {
  docker rm -f ${container_name} || true
}
cleanup
trap cleanup EXIT

docker run -d --name ${container_name} -p 18000-18010:18000-18010 \
  -v "${base_dir}/../:/nginx-lua-prometheus" ${image_name} \
  nginx -c /nginx-lua-prometheus/integration/nginx.conf

RC=0
go run . || RC=$?

nginx_logs 2>&1 | tail -30

echo Exiting with code $RC
exit $RC
