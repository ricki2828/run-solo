#!/usr/bin/env bash
# CI file hand-off through GitHub Releases (they do not count against Actions artifact storage,
# which is capped at 500 MB on the private free plan). All releases are prereleases.
# Needs the gh CLI and GH_TOKEN (the job needs `contents: write` to publish).
#   ci_release.sh put <tag> <title> <notes> [--replace-assets] <file>...   create/update, upload
#   ci_release.sh get <tag> <dir> [pattern]                                download assets
#   ci_release.sh drop <tag>                                               delete release + tag
#   ci_release.sh prune <tag-prefix> <days>                                delete older releases
set -euo pipefail
cmd="${1:?put|get|drop|prune}"; shift
case "$cmd" in
  put)
    tag="${1:?tag}"; title="${2:?title}"; notes="${3:?notes}"; shift 3
    replace=0
    if [ "${1:-}" = "--replace-assets" ]; then replace=1; shift; fi
    if gh release view "$tag" > /dev/null 2>&1; then
      gh release edit "$tag" --title "$title" --notes "$notes" --prerelease > /dev/null
    else
      # Matrix siblings can race to create the same release; the loser just reuses it.
      gh release create "$tag" --prerelease --target main --title "$title" --notes "$notes" > /dev/null \
        || gh release view "$tag" > /dev/null
    fi
    if [ "$replace" = 1 ]; then
      keep="$(for f in "$@"; do basename "$f"; done)"
      gh release view "$tag" --json assets -q '.assets[].name' | while read -r asset; do
        grep -qxF "$asset" <<< "$keep" || gh release delete-asset "$tag" "$asset" --yes
      done
    fi
    gh release upload "$tag" "$@" --clobber
    echo "published to release $tag: $(for f in "$@"; do basename "$f"; done | tr '\n' ' ')"
    ;;
  get)
    tag="${1:?tag}"; dir="${2:?dir}"; pattern="${3:-}"
    mkdir -p "$dir"
    if [ -n "$pattern" ]; then
      gh release download "$tag" --dir "$dir" --pattern "$pattern" --clobber
    else
      gh release download "$tag" --dir "$dir" --clobber
    fi
    ;;
  drop)
    gh release delete "${1:?tag}" --cleanup-tag --yes 2> /dev/null || echo "no release $1 to drop"
    ;;
  prune)
    prefix="${1:?prefix}"; days="${2:?days}"
    cutoff="$(date -u -d "-$days days" +%s)"
    gh release list --limit 300 --json tagName,createdAt -q '.[] | [.tagName, .createdAt] | @tsv' | while IFS=$'\t' read -r tag created; do
      case "$tag" in
        "$prefix"*)
          if [ "$(date -u -d "$created" +%s)" -lt "$cutoff" ]; then
            gh release delete "$tag" --cleanup-tag --yes && echo "pruned $tag ($created)"
          fi
          ;;
      esac
    done
    ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac
