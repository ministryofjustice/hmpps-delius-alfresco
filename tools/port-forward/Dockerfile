FROM alpine:3

RUN apk add --update --no-cache socat \
    && rm -rf /var/cache/apk/

RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

USER 1001

CMD ["sh", "-c", "socat tcp-listen:$LOCAL_PORT,reuseaddr,fork tcp:$REMOTE_HOST:$REMOTE_PORT & pid=$! && trap \"kill $pid\" SIGINT && echo \"Socat started listening on $LOCAL_PORT: Redirecting traffic to $REMOTE_HOST:$REMOTE_PORT ($pid)\" && wait $pid"]
