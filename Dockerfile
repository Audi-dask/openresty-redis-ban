FROM openresty/openresty:1.25.3.2-alpine-fat

RUN opm get openresty/lua-resty-redis

COPY conf/ /usr/local/openresty/nginx/conf/
COPY lua/ /usr/local/openresty/lua/
COPY html/ /usr/local/openresty/nginx/html/
