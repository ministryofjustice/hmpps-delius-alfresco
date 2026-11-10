FROM postgres:16

RUN apt-get update && \
    apt-get install -y curl jq && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /var/lib/postgresql