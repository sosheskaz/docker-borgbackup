FROM alpine:3.14

RUN apk -U add --virtual build-deps acl-dev g++ gcc linux-headers musl-dev openssl-dev py3-pip python3-dev zstd-dev \
  && apk add libacl libbz2 libffi ncurses-libs openssh python3 sqlite-libs xz-libs zstd-libs \
  && pip3 install borgbackup \
  && apk del build-deps \
  && rm -rf /var/cache/apk
