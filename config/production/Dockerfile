FROM alpine:3.2
MAINTAINER Peyton Vaughn <pvaughn@6fusion.com>

ENV BUILD_PACKAGES build-base curl-dev libffi-dev  zlib-dev ruby-dev
ENV RUBY_PACKAGES nodejs ruby ruby-bundler ruby-io-console ruby-nokogiri ruby-bigdecimal ruby-rake
ENV RUNTIME_PACKAGES ca-certificates

ENV METER_ENV development
ENV RAILS_ENV production
ENV RAILS_SERVE_STATIC_FILES true

ENV RELEASE_NOTES https://registry.hub.docker.com/u/6fusion/vmware-meter/

RUN mkdir -p /usr/src/app
WORKDIR  /usr/src/app
COPY . /usr/src/app
COPY ./config/production/cloud-config.yml /usr/share/oem/

# Update and install all of the required packages, then remove build dependencies
# Note: Multiple run statements = multiple layers = bigger images, so we avoid that with the one monolithic statement
RUN apk update && \
    apk upgrade && \
    apk add $BUILD_PACKAGES && \
    apk add $RUBY_PACKAGES && \
    apk add $RUNTIME_PACKAGES && \
    bundle install --without development test assets && \
    apk del $BUILD_PACKAGES && \
    apk del musl openrc gdbm && \
    apk add $RUBY_PACKAGES && \
    rm -rf /var/cache/apk/* && \
    rm -rf /usr/src/app/config && \
    find / -iname "*.md" -exec rm {} \;

#    gem uninstall -aIx actionmailer coffee-rails coffee-script coffee-script-source json mail test-unit && \
#    rm -rf /usr/lib/ruby/gems/*/cache/ && \

CMD ["/bin/sh"]

