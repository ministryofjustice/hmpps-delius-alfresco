#!/usr/bin/env python3
# opensearch-list-unindexed-docs.py
#
# Lists all document IDs from an OpenSearch index using legacy Scroll API that have not been content indexed.
# Also supports PIT + search_after (recommended) via --method pit.
# However, you can only use PIT with a domain running OpenSearch version 2.5 or later.
# Designed to be run on the utils pod so it uses urllib only, as opposed to the requests module.
#
# Usage examples:
#   python3 opensearch-list-unindexed-docs.py --url http://my-opensearch-host:9200
#   python3 opensearch-list-unindexed-docs.py --method scroll --size 2000 --outfile unids.txt
#
# To run on utils pod, get URL from Kubernetes secret e.g.
# ns="hmpps-delius-alfresco-dev"
# script="opensearch-list-unindexed-docs.py"
# pod=$(kubectl -n "$ns" get pods -l app=utils -o name 2>/dev/null | head -n1 | cut -d/ -f2 || true)
# PROXY_URL=$(kubectl -n "$ns" get secret opensearch-output -o jsonpath='{.data.PROXY_URL}' | base64 --decode)
# kubectl -n $ns cp scripts/${script} ${pod}:/home/job/${script}
# kubectl -n "$ns" exec "$pod" -- bash -lc "nohup python3 ./$script --url $PROXY_URL &"
#
import argparse
import json
import sys
import urllib.parse
import urllib.request
import urllib.error
from typing import Dict, Any, Optional, Tuple, Literal

DEFAULT_URL  = "http://localhost:8080"

# --------------------
# HTTP helpers (stdlib)
# --------------------
def http_post(url: str, payload: Optional[Dict[str, Any]] = None,
              headers: Optional[Dict[str, str]] = None, timeout: int = 120) -> Dict[str, Any]:
    if headers is None:
        headers = {"Content-Type": "application/json"}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            charset = resp.headers.get_content_charset() or "utf-8"
            body = resp.read().decode(charset, errors="replace")
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        # Re-raise with context (also return server body to stderr for debugging)
        sys.stderr.write(f"[HTTPError] {e.code} {e.reason} for {url}\n")
        try:
            sys.stderr.write(e.read().decode("utf-8", errors="replace") + "\n")
        except Exception:
            pass
        raise
    except urllib.error.URLError as e:
        sys.stderr.write(f"[URLError] {e.reason} for {url}\n")
        raise

def join_url(*parts: str) -> str:
    return "/".join(s.strip("/") for s in parts if s is not None)

# ---------------------------------------
# PIT open/close with endpoint auto-detect
# ---------------------------------------
PITMode = Literal["point_in_time_global", "point_in_time_index", "pit_legacy"]

def try_open_pit(base_http: str, index: str, keep_alive: str) -> Tuple[str, PITMode]:
    """
    Attempts PIT open using 3 variants. Returns (pit_id, mode).
    Order:
      1) POST /_search/point_in_time?keep_alive=...  body: {"index":"<index>"}   -> {"pit_id": "..."}
      2) POST /{index}/_search/point_in_time?keep_alive=...  body: {}            -> {"pit_id": "..."}
      3) POST /{index}/_pit  body: {"keep_alive":"..."}                           -> {"id": "..."}
    """
    # Variant 1: global point_in_time with index in body
    url1 = f"{join_url(base_http, '_search', 'point_in_time')}?{urllib.parse.urlencode({'keep_alive': keep_alive})}"
    try:
        resp1 = http_post(url1, {"index": index})
        pit_id = resp1.get("pit_id")
        if pit_id:
            return pit_id, "point_in_time_global"
    except Exception:
        pass

    # Variant 2: index-scoped point_in_time with empty body
    url2 = f"{join_url(base_http, index, '_search', 'point_in_time')}?{urllib.parse.urlencode({'keep_alive': keep_alive})}"
    try:
        resp2 = http_post(url2, {})
        pit_id = resp2.get("pit_id")
        if pit_id:
            return pit_id, "point_in_time_index"
    except Exception:
        pass

    # Variant 3: legacy _pit
    url3 = join_url(base_http, index, "_pit")
    try:
        resp3 = http_post(url3, {"keep_alive": keep_alive})
        pit_id = resp3.get("id")
        if pit_id:
            return pit_id, "pit_legacy"
    except Exception:
        pass

    raise RuntimeError(
        "Failed to open PIT using all known endpoints. "
        "Your cluster may not support PIT; use --method scroll as a fallback."
    )

def close_pit(base_http: str, pit_id: str, mode: PITMode) -> None:
    """
    Close the PIT/point_in_time depending on mode.
      - point_in_time* : POST/DELETE /_search/point_in_time  body: {"pit_id":"..."}
      - pit_legacy     : POST/DELETE /_pit                   body: {"id":"..."}
    We'll try POST first (widely accepted via proxies), then ignore failures.
    """
    try:
        if mode in ("point_in_time_global", "point_in_time_index"):
            http_post(join_url(base_http, "_search", "point_in_time"), {"pit_id": pit_id})
        else:
            http_post(join_url(base_http, "_pit"), {"id": pit_id})
    except Exception:
        # Best-effort close; many clusters auto-expire PITs
        pass

# -----------------------------------------
# PIT + search_after (recommended approach)
# -----------------------------------------
def list_ids_with_pit(base_http: str, index: str, size: int, outfile: str, keep_alive: str = "5m") -> None:
    pit_id, mode = try_open_pit(base_http, index, keep_alive)
    sys.stderr.write(f"PIT opened (mode={mode})\n")

    total = 0
    search_after = None

    try:
        with open(outfile, "w", encoding="utf-8") as fh:
            while True:
                body = {
                    "size": size,
                    "pit": {"id": pit_id, "keep_alive": keep_alive},
                    # Use stable/tiebreaker sort. _shard_doc is a good PIT tiebreaker.
                    "sort": [
                        {"_id": "asc"},
                        {"_shard_doc": "asc"}
                    ],
                    "_source": False,
                    "track_total_hits": True,
                    # If you need filtering, drop your query here:
                    # "query": { ... }
                }
                if search_after is not None:
                    body["search_after"] = search_after

                resp = http_post(join_url(base_http, "_search?filter_path=hits.hits._id,hits.hits.sort"), body)
                hits = (resp.get("hits") or {}).get("hits") or []
                if not hits:
                    break

                for h in hits:
                    _id = h.get("_id")
                    if _id:
                        fh.write(f"{_id}\n")
                        total += 1

                last_sort = hits[-1].get("sort")
                if not last_sort:
                    break
                search_after = last_sort

        print(f"Saved {total} IDs to {outfile}")
    finally:
        close_pit(base_http, pit_id, mode)

# -----------
# Scroll API
# -----------
def list_ids_with_scroll(base_http: str, index: str, size: int, outfile: str, scroll_ttl: str = "1m") -> None:
    params = {
      "scroll": scroll_ttl,
      "filter_path": "_scroll_id,hits.hits._id"
    }
    search_url = f"{join_url(base_http, index, '_search')}?{urllib.parse.urlencode(params)}"

    # Delete the METADATA_INDEXING_LAST_UPDATE range filter to get all unindexed docs
    body = {
        "size": size,
        "sort": [{"cm%3Acreated": "desc"}],
        "_source": False,
        "track_total_hits": True,
        "query": {
            "bool": {
            "must": [
                { "match": { "CONTENT_INDEXING_LAST_UPDATE": "0" }},
                { "match": { "TYPE": "nspg:offenderDocument" }}
            ],
            "must_not" : [
                { "match" : { "cm%3Acontent%2Etr_status": "TRANSFORM_FAILED"}},
                { "match" : { "cm%3Aname": "YSW*"}},
                { "match" : { "cm%3Acontent%2Emimetype": "image/jpeg"}},
                { "match" : { "cm%3Acontent%2Emimetype": "image/png"}},
                { "match" : { "cm%3Acontent%2Emimetype": "application/octet-stream"}},
                { "match" : { "cm%3Acontent%2Emimetype": "image/gif"}},
                { "match" : { "cm%3Acontent%2Emimetype": "image/bmp"}},
                { "match" : { "cm%3Acontent%2Emimetype": "video/mp4"}},
                { "match" : { "cm%3Acontent%2Emimetype": "audio/mpeg"}},
                { "match" : { "cm%3Acontent%2Emimetype": "audio/x-wav"}},
                { "match" : { "cm%3Acontent%2Emimetype": "audio/mp4"}},
                { "match" : { "cm%3Acontent%2Emimetype": "image/tiff"}},
                { "match" : { "cm%3Acontent%2Emimetype": "video/quicktime"}},
                { "match" : { "cm%3Acontent%2Emimetype": "audio/x-flac"}},
                { "match":  { "cm%3Acontent%2Esize": "0" }}
            ],
            "filter": [
                { "range": { "cm%3Acontent%2Esize": { "lte": "26214400" }}},
                { "range": { "METADATA_INDEXING_LAST_UPDATE": {"gte": "1499390026734"}}}
            ]  
            }
        }
    }
    resp = http_post(search_url, body)
    scroll_id = resp.get("_scroll_id")
    hits = (resp.get("hits") or {}).get("hits") or []

    total = 0
    with open(outfile, "w", encoding="utf-8") as fh:
        while True:
            for h in hits:
                _id = h.get("_id")
                if _id:
                    fh.write(f"{_id}\n")
                    total += 1

            if not scroll_id:
                break

            # Next page
            scroll_resp = http_post(join_url(base_http, "_search", "scroll"), {
                "scroll": scroll_ttl,
                "scroll_id": scroll_id
            })
            scroll_id = scroll_resp.get("_scroll_id")
            hits = (scroll_resp.get("hits") or {}).get("hits") or []
            if not hits:
                break

    print(f"Saved {total} IDs to {outfile}")

    # Best-effort clear scroll
    if scroll_id:
        try:
            http_post(join_url(base_http, "_search", "scroll"), {"scroll_id": scroll_id})
        except Exception:
            pass

# ----
# CLI
# ----
def main():
    parser = argparse.ArgumentParser(description="List all document IDs from an OpenSearch/Elasticsearch index (urllib only).")
    parser.add_argument("--url", default=DEFAULT_URL, help="OpenSearch URL")
    parser.add_argument("--index", default="alfresco", help="Index name")
    parser.add_argument("--size", type=int, default=1000, help="Page size")
    parser.add_argument("--outfile", default="unids.txt", help="Output file for IDs")
    parser.add_argument("--method", choices=["pit", "scroll"], default="scroll", help="Pagination method")
    parser.add_argument("--keep-alive", default="5m", help="PIT/scroll keep_alive (e.g. 5m, 1m)")
    args = parser.parse_args()

    base_http = f"{args.url}"

    if args.method == "pit":
        list_ids_with_pit(base_http, args.index, args.size, args.outfile, keep_alive=args.keep_alive)
    else:
        list_ids_with_scroll(base_http, args.index, args.size, args.outfile, scroll_ttl=args.keep_alive)

if __name__ == "__main__":
    main()