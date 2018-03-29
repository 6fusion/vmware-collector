FROM alpine:3.6
MAINTAINER 6fusion dev <dev@6fusion.com>

ENV BUILD_PACKAGES build-base curl-dev libffi-dev zlib-dev pkgconfig libxml2-dev libxslt-dev
ENV RUBY_PACKAGES ruby ruby-bundler ruby-dev ruby-nokogiri ruby-bigdecimal libxml2 libxslt
ENV RUNTIME_PACKAGES ca-certificates bash tzdata

ENV METER_ENV production

LABEL vendor="6fusion USA, Inc."  \
      version=""  \
      release=""  \
      commit="$GIT_COMMIT" \
      url="https://6fusion.com"

WORKDIR /app
COPY . /app

RUN apk update && \
  apk upgrade && \
  apk add $BUILD_PACKAGES $RUBY_PACKAGES $RUNTIME_PACKAGES && \
  bundle config build.nokogiri --use-system-libraries && \
  bundle install --without test && \
  rm -rf .git .gitignore .vagrant init-ssl* secrets_example spec ssl test Vagrantfile && \
  bundle clean --force && \
  apk del $BUILD_PACKAGES && \
  rm -rf /var/cache/apk/*


ENTRYPOINT ["ruby", "bin/inventory-collector.rb"]
