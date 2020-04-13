#!/bin/bash

# This script updates the lua-resty-counter [1] included with this library
# for convenience.
# [1] https://github.com/Kong/lua-resty-counter

set -exu
URL='https://raw.githubusercontent.com/Kong/lua-resty-counter/master/lib/resty/counter.lua'
curl -s ${URL} > prometheus_resty_counter.lua
