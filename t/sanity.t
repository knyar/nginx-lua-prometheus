use Test::Nginx::Socket::Lua 'no_plan';
use Cwd qw(cwd);

workers(1);
no_shuffle();

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/?.lua;$pwd/deps/share/lua/5.1/?.lua;;";
    lua_shared_dict metrics 8m;

    init_by_lua_block {
        luaunit = require('luaunit')
        prometheus = require('prometheus')
        dict = ngx.shared.metrics
    }
};

run_tests();

__DATA__

=== TEST 1: testInit
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            luaunit.assertEquals(dict:get("nginx_metric_errors_total"), nil)
            luaunit.assertEquals(ngx.logs, nil)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- no_error_log
[error]



=== TEST 2: testErrorUnitialized
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local p = prometheus
            p:counter("metric1")
            p:histogram("metric2")
            p:gauge("metric3")
            p:metric_data()
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- grep_error_log eval
qr/\[error\].*/
--- grep_error_log_out eval
[
    qr/Prometheus module has not been initialized/,
    qr/Prometheus module has not been initialized/,
    qr/Prometheus module has not been initialized/,
    qr/Prometheus module has not been initialized/
]



=== TEST 3: testErrorUnknownDict
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local p = prometheus.init("nonexistent")
            luaunit.assertEquals(p.initialized, false)
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done
--- grep_error_log eval
qr/\[error\].*/
--- grep_error_log_out eval
qr/does not seem to exist/
