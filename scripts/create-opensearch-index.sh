#!/bin/bash
###########
# Create opensearch index with correct parameters
# Usage: create-opensearch-index.sh <index-name> <shards> <replicas>
# Portforward the opensearch domain with ./tools/scripts/opensearch-connect.sh <env> first
###########

# create opensearch index
curl -X PUT "localhost:8080/$1" -H 'Content-Type: application/json' -d'
{
  "settings": {
    "index": {
      "number_of_shards": '$2',
      "number_of_replicas": '$3'
    }
  }
}'

# increase maximum fields limit (alfresco seems to need just over 1000 which is the default)
curl -XPUT "localhost:8080/$1/_settings" -H "Content-Type: application/json" -d'
{
  "index.mapping.total_fields.limit": 2000
}'

# The refresh interval is the time in which indexed data is searchable and should be disabled. This is done by setting it to -1 or by setting it to a higher value during indexing to avoid the unnecessary usage of resources.
curl -XPUT "localhost:8080/$1/_settings" -H 'Content-Type: application/json' -d '{ "index" : { "refresh_interval" : "-1"  }}'

# set the translog flush threshold to 2GB
curl -XPUT "localhost:8080/$1/_settings" -H 'Content-Type: application/json' -d '{ "index" : { "translog" : { "flush_threshold_size" : "2gb"  }} }'

# set the max docvalue fields search to 150
curl -XPUT "localhost:8080/$1/_settings" -H 'Content-Type: application/json' -d '{ "index" : { "max_docvalue_fields_search" : "150"  }}'
