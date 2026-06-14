#!/bin/sh
#
# Sync this fork using the branch model:
#   master          mirrors upstream FFmpeg master
#   origin/master   mirrors upstream FFmpeg master on the fork
#   learning        contains local additions on top of master
#   origin/learning mirrors learning on the fork
#
# Defaults can be overridden with environment variables:
#   ORIGIN_REMOTE=origin
#   UPSTREAM_REMOTE=upstream
#   UPSTREAM_URL=https://github.com/FFmpeg/FFmpeg.git
#   BASE_BRANCH=master
#   WORK_BRANCH=learning

set -eu

origin_remote=${ORIGIN_REMOTE:-origin}
upstream_remote=${UPSTREAM_REMOTE:-upstream}
upstream_url=${UPSTREAM_URL:-https://github.com/FFmpeg/FFmpeg.git}
base_branch=${BASE_BRANCH:-master}
work_branch=${WORK_BRANCH:-learning}
push_changes=1
dry_run=0

usage() {
    cat <<EOF
Usage: $0 [--no-push] [--dry-run]

Synchronizes:
  ${base_branch} -> ${upstream_remote}/${base_branch}
  ${origin_remote}/${base_branch} -> ${upstream_remote}/${base_branch}
  ${work_branch} merges ${base_branch}
  ${origin_remote}/${work_branch} -> ${work_branch}

Options:
  --no-push   update local branches only
  --dry-run   print commands without executing them
  -h, --help  show this help
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

run() {
    printf '+'
    printf ' %s' "$@"
    printf '\n'

    if [ "$dry_run" -eq 0 ]; then
        "$@"
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-push)
            push_changes=0
            ;;
        --dry-run)
            dry_run=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
    shift
done

git rev-parse --show-toplevel >/dev/null 2>&1 ||
    die "not inside a Git repository"

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [ -n "$(git status --porcelain)" ]; then
    git status -sb
    die "working tree is not clean; commit or stash changes first"
fi

git remote get-url "$origin_remote" >/dev/null 2>&1 ||
    die "missing origin remote: $origin_remote"

if git remote get-url "$upstream_remote" >/dev/null 2>&1; then
    :
else
    run git remote add "$upstream_remote" "$upstream_url"
fi

run git fetch "$upstream_remote" \
    "$base_branch:refs/remotes/$upstream_remote/$base_branch"
run git fetch "$origin_remote"

if [ "$dry_run" -eq 1 ]; then
    printf '\nDry run only. No branches were changed.\n'
    exit 0
fi

git rev-parse --verify "$upstream_remote/$base_branch" >/dev/null 2>&1 ||
    die "missing $upstream_remote/$base_branch after fetch"

if ! git show-ref --verify --quiet "refs/heads/$base_branch"; then
    run git branch "$base_branch" "$upstream_remote/$base_branch"
fi

if ! git show-ref --verify --quiet "refs/heads/$work_branch"; then
    if git rev-parse --verify "$origin_remote/$work_branch" >/dev/null 2>&1; then
        run git branch "$work_branch" "$origin_remote/$work_branch"
    else
        run git branch "$work_branch" "$base_branch"
    fi
fi

if git rev-parse --verify "$origin_remote/$work_branch" >/dev/null 2>&1; then
    if git merge-base --is-ancestor "$work_branch" "$origin_remote/$work_branch"; then
        run git switch "$work_branch"
        run git merge --ff-only "$origin_remote/$work_branch"
    elif git merge-base --is-ancestor "$origin_remote/$work_branch" "$work_branch"; then
        :
    else
        die "$work_branch and $origin_remote/$work_branch have diverged"
    fi
fi

run git switch "$base_branch"
run git reset --hard "$upstream_remote/$base_branch"

if [ "$push_changes" -eq 1 ]; then
    run git push "$origin_remote" "$base_branch:$base_branch"
fi

if ! git merge-base --is-ancestor "$base_branch" "$work_branch"; then
    if ! git merge-tree --write-tree "$work_branch" "$base_branch" >/dev/null; then
        die "merging $base_branch into $work_branch would conflict"
    fi

    run git switch "$work_branch"
    run git merge --no-edit "$base_branch"
else
    run git switch "$work_branch"
fi

if [ "$push_changes" -eq 1 ]; then
    run git push "$origin_remote" "$work_branch:$work_branch"
fi

printf '\nSynced branch state:\n'
git status -sb
git log -1 --oneline --decorate
