FROM openresty/openresty:bookworm-fat
RUN sed -i '/^pcre_jit on;/a error_log /proc/self/fd/2 info;' /usr/local/openresty/nginx/conf/nginx.conf
