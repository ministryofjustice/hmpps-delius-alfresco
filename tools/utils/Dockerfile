FROM debian:bookworm-slim

# Install utils
RUN apt-get update && apt-get install -y curl jq

# Create a non-root user and set the home directory
RUN useradd -u 999 -ms /bin/bash job
USER job
WORKDIR /home/job
