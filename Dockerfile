FROM alpine
RUN apk add --no-cache git
COPY git-sync-remote /usr/local/bin

