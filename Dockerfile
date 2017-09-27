FROM alpine
RUN apk add --no-cache git openssh-client
COPY git-sync-remote /usr/local/bin

