#!/bin/sh ## Pull listings *at GitHub* from jobs.github.com. Output markdown.

curl -s 'https://jobs.github.com/positions.json?description=company:"GitHub"'|
  jq . | grep '"url"' | sed 's|.* "\(.*\)"|\1|' |
    while read job; do
      curl -Ls "$job.json?markdown=true" | sed "s|\\\r\\\n|~|g" | tr '~' '\n'|
                    sed "s|\\\t|  |g" | jq . | sed "s|\\\n|~|g" | tr '~' '\n'|
      sed -e's|  "title": "\(.*\)",|#Title: \1|' -e's|  "description": "||'  |
      grep -v '^  ".*' | sed -e 's|",||g' -e 's|[{}]||g' -e 's|       | |g'
    done
