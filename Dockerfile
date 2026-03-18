FROM nimlang/nim:2.2.0-alpine-regular as nim
LABEL maintainer="setenforce@protonmail.com"

RUN apk --no-cache add libsass-dev pcre

WORKDIR /src/nitter

COPY nitter.nimble .
RUN nimble install -y --depsOnly

COPY . .
RUN nimble build -d:release -d:strip --mm:orc \
    && nimble scss

FROM alpine:latest
WORKDIR /src/
RUN apk --no-cache add pcre ca-certificates su-exec
COPY --from=nim /src/nitter/nitter ./
COPY --from=nim /src/nitter/nitter.example.conf ./nitter.conf
COPY --from=nim /src/nitter/public ./public
COPY docker-entrypoint.sh ./docker-entrypoint.sh
EXPOSE 8080
RUN adduser -h /src/ -D -s /bin/sh nitter
RUN chmod 755 ./docker-entrypoint.sh
CMD ["./docker-entrypoint.sh"]
