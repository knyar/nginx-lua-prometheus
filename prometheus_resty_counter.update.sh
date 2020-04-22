#!/bin/bash

# This script downloads the lua-resty-counter [1] included with this library
# for convenience. It's here to make it easier to update the "vendored" lua
# file in this repo. As a user, you should not need to use this script.
# [1] https://github.com/Kong/lua-resty-counter

set -exu
URL='https://raw.githubusercontent.com/Kong/lua-resty-counter/master/lib/resty/counter.lua'
curl -s ${URL} > prometheus_resty_counter.lua
