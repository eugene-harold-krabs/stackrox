#!/usr/bin/env bash
#
# Rebases open PRs labeled `auto-rebase` onto their base branch whenever they
# fall behind, regardless of CI check status.
#
# PRs from forks are skipped, as the bot has no push access to them.
# Conflicts are reported once per head commit via a PR comment instead of
# being retried automatically on every run.
#
set -euo pipefail
set -x # Temporary command tracing for PR validation

check_not_empty GITHUB_REPOSITORY

PRS=$(gh pr list \
    --search "label:auto-rebase" \
    --state open \
    --limit 1000 \
    --json number,headRefName,baseRefName,isCrossRepository,headRefOid \
    --jq '.[] | [
        .number,
        .headRefName,
        .baseRefName,
        .isCrossRepository,
        .headRefOid
    ] | @tsv')

if [ -z "$PRS" ]; then
    gh_log debug "No open PRs with the auto-rebase label."
    exit 0
fi

rebase_pr() {
    IFS=$'\t' read -r PR HEAD_REF BASE_REF IS_FORK HEAD_SHA <<<"$1"

    if [ "$IS_FORK" = "true" ]; then
        gh_log debug "#$PR is from a fork ($HEAD_REF); auto-rebase only supports branches on this repository."
        return
    fi

    git fetch origin \
        "$BASE_REF:refs/remotes/origin/$BASE_REF" \
        "$HEAD_REF:refs/remotes/origin/$HEAD_REF"

    FETCHED_SHA=$(git rev-parse "origin/$HEAD_REF")
    if [ "$FETCHED_SHA" != "$HEAD_SHA" ]; then
        gh_log debug "#$PR head changed; skipping until next run."
        return
    fi

    if git merge-base --is-ancestor "origin/$BASE_REF" "origin/$HEAD_REF"; then
        gh_log debug "#$PR is already up to date with $BASE_REF."
        return
    fi

    git checkout -B "$HEAD_REF" "origin/$HEAD_REF"

    if ! git rebase "origin/$BASE_REF"; then
        git rebase --abort
        git checkout -

        local MARKER="Auto-rebase onto \`$BASE_REF\` failed due to conflicts at commit \`$HEAD_SHA\`."
        if gh pr view "$PR" --json comments --jq '.comments[].body' | grep -qF "$MARKER"; then
            gh_log debug "#$PR conflict already reported for $HEAD_SHA."
        else
            gh pr comment "$PR" --body "$MARKER Please rebase \`$HEAD_REF\` onto \`$BASE_REF\` manually."
            gh_summary "#$PR (\`$HEAD_REF\`) has conflicts with \`$BASE_REF\`; commented asking for a manual rebase."
        fi
        return
    fi

    if ! git push --force-with-lease origin "$HEAD_REF:$HEAD_REF"; then
        gh_log warning "#$PR could not be pushed; will retry next run."
        git checkout -
        return
    fi

    gh_summary "#$PR (\`$HEAD_REF\`) has been rebased onto \`$BASE_REF\`."
    git checkout -
}

while read -r PR_LINE; do
    rebase_pr "$PR_LINE"
done <<<"$PRS"
