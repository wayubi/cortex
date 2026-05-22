FROM openresty/openresty:bookworm-fat
RUN opm get ledgetech/lua-resty-http && \
    sed -i '1i user root;' /usr/local/openresty/nginx/conf/nginx.conf
