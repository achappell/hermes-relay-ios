# Story issue tracking

The local BMAD artifacts remain authoritative for story scope, validation, and
status. GitHub issues and Project #3 mirror the accepted story records.

For an iOS story, lookup prefers `github_issue` in
`_bmad-output/implementation-artifacts/story-index.yaml`. When no URL is stored,
the workflow matches the exact `Sprint Key` marker in the issue body or the full
story key in the title. Pull requests are excluded; multiple matches stop the
workflow instead of guessing. Newly discovered issue URLs are written back to
the story index without committing other staged files.

Story pull requests target their PRD branch. Completion checks use that exact
pull request and its current head revision, including required checks that do
not come from GitHub Actions. A missing pull request or missing checks is not
green. The workflow waits for a result before changing the issue to `done` or
closing it.

BMAD setup can regenerate the runtime copies under
`_bmad/_config/custom/workflows/common/`. The repository-owned sources are in
`_bmad/custom/repo-issue-tracking/workflows/common/`. After refreshing BMAD,
run `scripts/apply_repo_issue_tracking_overrides.sh`; CI checks that the runtime
copies still match with `--check`.
