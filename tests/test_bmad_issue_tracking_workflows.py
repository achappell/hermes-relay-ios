from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / "_bmad/_config/custom/workflows/common"


class IssueTrackingWorkflowTests(unittest.TestCase):
    def test_issue_lookup_prefers_index_then_exact_key(self) -> None:
        workflow = (WORKFLOWS / "find-issue.yaml").read_text(encoding="utf-8")
        indexed = workflow.index("scripts/bmad_issue_tracking.py issue-id")
        exact_key = workflow.index("scripts/bmad_issue_tracking.py search-issue-id")
        broad_platform_search = workflow.index("glab api")
        self.assertLess(indexed, exact_key)
        self.assertLess(exact_key, broad_platform_search)

        ensure_issue = (WORKFLOWS / "ensure-issue.yaml").read_text(encoding="utf-8")
        self.assertIn("**Sprint Key:** `{story_key}`", ensure_issue)
        self.assertIn("record-issue-url", ensure_issue)

    def test_story_pr_is_created_before_ci_and_status_update(self) -> None:
        workflow = (WORKFLOWS / "post-dev-complete.yaml").read_text(encoding="utf-8")
        dev_finish = workflow.split("# PHASE 2:", maxsplit=1)[1].split(
            "# PHASE 3:", maxsplit=1
        )[0]
        self.assertLess(
            dev_finish.index("common/ensure-story-mr"),
            dev_finish.index("common/wait-for-green-ci"),
        )
        self.assertLess(
            dev_finish.index("common/wait-for-green-ci"),
            dev_finish.index("common/update-issue-status"),
        )
        self.assertLess(
            dev_finish.index("issue_url_record_status"),
            dev_finish.index('git commit --allow-empty -m "dev'),
        )
        self.assertIn('git commit --only -m "track issue {story_key}"', workflow)

    def test_story_pr_targets_its_prd_and_checks_that_exact_pr(self) -> None:
        ensure_pr = (WORKFLOWS / "ensure-story-mr.yaml").read_text(encoding="utf-8")
        get_checks = (WORKFLOWS / "get-mr-pipeline.yaml").read_text(encoding="utf-8")
        self.assertIn('value: "{prd_branch}"', ensure_pr)
        self.assertIn('gh pr edit {mr_iid} --base "{prd_branch}"', ensure_pr)
        self.assertIn("gh pr checks {mr_iid}", get_checks)
        self.assertIn('--commit "{pr_head_sha}"', get_checks)
        self.assertNotIn('gh run list --limit 1 -R "{mr_repo}"', get_checks)

    def test_missing_pr_or_checks_are_not_written_as_green(self) -> None:
        ci_status = (WORKFLOWS / "write-ci-status.yaml").read_text(encoding="utf-8")
        self.assertIn(
            '"status": "red", "diagnostic": "No PR checks appeared"', ci_status
        )
        self.assertIn(
            '"status": "red", "diagnostic": "No PR exists for this story branch"',
            ci_status,
        )

    def test_status_update_creates_labels_before_using_them(self) -> None:
        workflow = (WORKFLOWS / "update-issue-status.yaml").read_text(encoding="utf-8")
        self.assertLess(
            workflow.index("INCLUDE: common/ensure-labels"),
            workflow.index("gh issue edit"),
        )

    def test_repo_owned_workflows_match_runtime_copies(self) -> None:
        result = subprocess.run(
            [str(ROOT / "scripts/apply_repo_issue_tracking_overrides.sh"), "--check"],
            cwd=ROOT,
            capture_output=True,
            check=False,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
