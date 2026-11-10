FROM postgres:16

RUN apt-get update && \
    apt-get install -y curl jq && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -u 1001 -ms /bin/bash job

USER job
WORKDIR /home/job