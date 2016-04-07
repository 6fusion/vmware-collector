FROM alpine:3.2
MAINTAINER Peyton Vaughn <pvaughn@6fusion.com>

ENV BUILD_PACKAGES build-base curl-dev libffi-dev gcc git zlib-dev
ENV RUBY_PACKAGES nodejs ruby ruby-bundler ruby-dev ruby-io-console ruby-nokogiri
ENV DEV_PACKAGES bash vim
ENV RUNTIME_PACKAGES ca-certificates

ENV METER_ENV development

ENV RELEASE_NOTES https://registry.hub.docker.com/u/6fusion/vmware-collector/

RUN mkdir -p /usr/src/app
WORKDIR  /usr/src/app
COPY .  /usr/src/app
COPY ./config/development/cloud-config.yml /usr/share/oem/

# Update and install all of the required packages.
# At the end, remove the apk cache
RUN apk update && \
    apk upgrade && \
    apk add $BUILD_PACKAGES $RUBY_PACKAGES $DEV_PACKAGES $RUNTIME_PACKAGES && \
    bundle install

CMD ["/bin/bash"]

