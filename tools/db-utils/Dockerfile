FROM debian:bookworm-slim

# Install psql client
RUN apt-get update && apt-get install -y postgresql-client
# Install curl 
RUN apt-get install -y curl
# Install jq
RUN apt-get install -y jq

# Create a non-root user and set the home directory
RUN useradd -u 999 -ms /bin/bash job
RUN mkdir /job
RUN chown -R job:job /job/
USER job

WORKDIR /job
