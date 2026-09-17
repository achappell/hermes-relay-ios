#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -gt 1 ]]; then
  printf '%s\n' "Usage: $0 [--check]" >&2
  exit 2
fi
mode="apply"
if [[ "$#" -eq 1 ]]; then
  mode="$1"
fi
if [[ "$mode" != "apply" && "$mode" != "--check" ]]; then
  printf '%s\n' "Usage: $0 [--check]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_root="$repo_root/_bmad/custom/repo-issue-tracking/workflows"
target_root="$repo_root/_bmad/_config/custom/workflows"

if [[ ! -d "$source_root" ]]; then
  printf '%s\n' "Repo issue-tracking workflow sources are missing." >&2
  exit 1
fi

stale=0
applied=0
while IFS= read -r -d '' source_file; do
  relative_path="$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$source_file" "$source_root")"
  target_file="$target_root/$relative_path"

  if [[ "$mode" == "--check" ]]; then
    if ! cmp -s "$source_file" "$target_file"; then
      printf '%s\n' "Stale repo issue-tracking workflow: $relative_path" >&2
      stale=1
    fi
    continue
  fi

  mkdir -p "$(dirname "$target_file")"
  if ! cmp -s "$source_file" "$target_file"; then
    cp "$source_file" "$target_file"
    printf '%s\n' "Applied repo issue-tracking workflow: $relative_path"
    applied=1
  fi
done < <(find "$source_root" -type f -name '*.yaml' -print0)

if [[ "$mode" == "--check" ]]; then
  exit "$stale"
fi

if [[ "$applied" == "0" ]]; then
  printf '%s\n' "Repo issue-tracking workflows are already current."
fi
