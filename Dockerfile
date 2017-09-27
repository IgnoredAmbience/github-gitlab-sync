FROM alpine
RUN apk add --no-cache git openssh-client
RUN mkdir -p ~/.ssh && \
    ssh-keyscan -H github.com >> ~/.ssh/known_hosts && \
    ssh-keyscan -H gitlab.com >> ~/.ssh/known_hosts && \
    ssh-keyscan -H gitlab.doc.ic.ac.uk >> ~/.ssh/known_hosts
COPY git-sync-remote /usr/local/bin

