FROM alpine:latest

RUN apk add --no-cache curl

COPY wrapper.sh /wrapper.sh
RUN chmod +x /wrapper.sh

ENTRYPOINT ["/wrapper.sh"]
