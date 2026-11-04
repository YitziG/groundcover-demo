FROM alpine:3.20

RUN apk add --no-cache bash curl
COPY load.sh /load.sh
RUN chmod 755 /load.sh
USER nobody
CMD ["/bin/bash", "/load.sh"]
