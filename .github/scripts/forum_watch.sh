#!/usr/bin/env bash
# Opens one GitHub issue for each new Elixir Forum post about this library that was not
# written by a maintainer. No AI involved: it reads the forum's public JSON and calls gh.
#
# Watched: every topic tagged TAG, plus search hits for the package name in other topics.
# Deduplication: each issue body carries "forum-post-<id>", and a post that already has
# an issue (open or closed) is skipped. Runs are safe to repeat.
#
# Environment:
#   IGNORE_USERS  comma-separated forum usernames to skip (maintainers, bots)
#   SINCE_DAYS    only posts newer than this many days (default 14)
#   DRY_RUN       "true" prints what would be opened and creates nothing
set -euo pipefail

FORUM="https://forum.elixirforum.com"
TAG="system-one-client"
PATTERN='system_one_client|systemoneclient|system-one-client'
IGNORE_USERS="${IGNORE_USERS:-schainks}"
SINCE_DAYS="${SINCE_DAYS:-14}"
DRY_RUN="${DRY_RUN:-false}"
LABEL="forum"

since="$(date -u -d "$SINCE_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ)"
since_day="${since%%T*}"
get() { curl -fsS --retry 3 --retry-delay 5 -H "Accept: application/json" "$1"; }

ignored() { case ",$IGNORE_USERS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Plain text from a post's HTML, with @ defused so forum names never ping GitHub users.
excerpt() {
  jq -r '.cooked' <<<"$1" | sed -e 's/<[^>]*>/ /g' -e 's/@/(at)/g' | tr -s '[:space:]' ' ' | cut -c1-1500
}

report() { # $1 = post JSON with id, topic_id, topic_slug, topic_title, post_number, username, created_at, cooked
  local id user created title url text
  id="$(jq -r '.id' <<<"$1")"
  user="$(jq -r '.username' <<<"$1")"
  created="$(jq -r '.created_at' <<<"$1")"
  title="$(jq -r '.topic_title' <<<"$1")"
  url="$FORUM/t/$(jq -r '.topic_slug' <<<"$1")/$(jq -r '.topic_id' <<<"$1")/$(jq -r '.post_number' <<<"$1")"

  if ignored "$user"; then return; fi
  if [[ "$created" < "$since" ]]; then return; fi

  if [ "$DRY_RUN" = "true" ]; then
    echo "would open: forum-post-$id by $user ($created) $url"
    return
  fi
  if [ -n "$(gh issue list --state all --search "\"forum-post-$id\" in:body" --json number --jq '.[].number')" ]; then
    return
  fi

  text="$(excerpt "$1")"
  gh issue create --label "$LABEL" \
    --title "Forum: post by $user in \"${title:0:80}\"" \
    --body "A new Elixir Forum post mentions this library.

- **Post:** $url
- **Author (forum username):** $user
- **Posted:** $created

> $text

Reply on the forum, then close this issue. If the post reports a bug or asks for a
feature, open a separate issue for it and link it here.

Ref: forum-post-$id"
  echo "opened issue for forum-post-$id"
}

posts_of_topic() { # $1 = topic id; prints one JSON object per post, newest 20 only
  local topic ids query
  topic="$(get "$FORUM/t/$1.json")"
  ids="$(jq -r '.post_stream.stream[-20:][]' <<<"$topic")"
  [ -z "$ids" ] && return
  query="$(printf 'post_ids[]=%s&' $ids)"
  get "$FORUM/t/$1/posts.json?${query%&}" |
    jq -c --argjson t "$(jq '{topic_id: .id, topic_slug: .slug, topic_title: .title}' <<<"$topic")" \
      '.post_stream.posts[] | {id, post_number, username, created_at, cooked} + $t'
}

if [ "$DRY_RUN" != "true" ]; then
  gh label create "$LABEL" --color 5319e7 --description "Mentions on Elixir Forum" --force > /dev/null
fi

seen=" "

# 1. Every topic carrying the library's tag.
for topic_id in $(get "$FORUM/tag/$TAG.json" | jq -r '.topic_list.topics[].id'); do
  while IFS= read -r post; do
    [ -z "$post" ] && continue
    seen="$seen$(jq -r '.id' <<<"$post") "
    report "$post"
  done < <(posts_of_topic "$topic_id")
done

# 2. Recent posts elsewhere that name the package. Forum search is fuzzy, so keep only
#    posts whose text really contains the name.
search="$(get "$FORUM/search.json?q=system_one_client%20after:$since_day%20order:latest")"
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  id="$(jq -r '.id' <<<"$hit")"
  case "$seen" in *" $id "*) continue ;; esac
  post="$(get "$FORUM/posts/$id.json")"
  if ! jq -r '.cooked' <<<"$post" | grep -qiE "$PATTERN"; then continue; fi
  report "$(jq -c '{id, post_number, username, created_at, cooked, topic_id, topic_slug, topic_title: (.topic_title // .topic_slug)}' <<<"$post")"
done < <(jq -c '.posts[]? | {id}' <<<"$search")

echo "forum watch done (since $since)"
