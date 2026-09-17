from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from scripts import bmad_issue_tracking


class IssueTrackingHelperTests(unittest.TestCase):
    def test_indexed_issue_url_matches_full_story_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "story-index.yaml"
            index.write_text(
                """schema_version: 1
stories:
  - id: 1-I-1
    title: Start an authorized Hermes turn
    github_issue: https://github.com/example/hermes-client/issues/15
""",
                encoding="utf-8",
            )

            self.assertEqual(
                bmad_issue_tracking.resolve_story_issue_id(
                    "1-i-1-start-an-authorized-hermes-turn",
                    host="github.com",
                    project="example/hermes-client",
                    platform="github",
                    index_path=index,
                ),
                "15",
            )

    def test_missing_or_unmatched_story_index_resolves_empty(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing_index = Path(directory) / "missing.yaml"
            self.assertEqual(bmad_issue_tracking.read_story_index(missing_index), {})
            self.assertEqual(
                bmad_issue_tracking.resolve_story_issue_id(
                    "1-i-1-future-story",
                    host="github.com",
                    project="example/hermes-client",
                    platform="github",
                    index_path=missing_index,
                ),
                "",
            )

    def test_story_index_prefix_collision_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "matches multiple"):
            bmad_issue_tracking.find_story_record(
                {"1-I-1": {}, "1-I-1-START": {}}, "1-i-1-start-turn"
            )

    def test_indexed_issue_url_must_match_configured_project(self) -> None:
        with self.assertRaisesRegex(ValueError, "configured project"):
            bmad_issue_tracking.issue_id_from_url(
                "https://github.com/other/repo/issues/15",
                host="github.com",
                project="example/hermes-client",
                platform="github",
            )

    def test_search_uses_exact_sprint_key_ignores_prs_and_prefix_titles(self) -> None:
        payload = {
            "items": [
                {
                    "number": 15,
                    "title": "1-i-1-start-turn",
                    "body": "**Sprint Key:** `1-i-1-start-turn`",
                    "pull_request": {"url": "https://api.github.com/pulls/15"},
                },
                {
                    "number": 16,
                    "title": "Unrelated title",
                    "body": "**Sprint Key:** `1-i-1-start-turn`",
                },
                {"number": 17, "title": "1-i-1-start-turn-duplicate", "body": ""},
            ]
        }

        self.assertEqual(
            bmad_issue_tracking.resolve_story_issue_id_from_search(
                json.dumps(payload), "1-i-1-start-turn"
            ),
            "16",
        )

    def test_search_matches_full_story_key_in_title(self) -> None:
        payload = {
            "items": [
                {"number": 18, "title": "Story 1-i-1-start-turn", "body": ""},
                {"number": 19, "title": "Story 1-i-1-start-turn-copy", "body": ""},
            ]
        }
        self.assertEqual(
            bmad_issue_tracking.resolve_story_issue_id_from_search(
                json.dumps(payload), "1-i-1-start-turn"
            ),
            "18",
        )

    def test_search_ambiguous_match_fails_closed(self) -> None:
        payload = {
            "items": [
                {"number": 15, "body": "**Sprint Key:** `1-i-1-start-turn`"},
                {"number": 16, "body": "**Sprint Key:** `1-i-1-start-turn`"},
            ]
        }
        with self.assertRaisesRegex(ValueError, "multiple GitHub issues: 15, 16"):
            bmad_issue_tracking.resolve_story_issue_id_from_search(
                json.dumps(payload), "1-i-1-start-turn"
            )

    def test_search_rejects_unexpected_response_shape(self) -> None:
        with self.assertRaisesRegex(TypeError, "unexpected response"):
            bmad_issue_tracking.resolve_story_issue_id_from_search("[]", "1-i-1-x")

    def test_created_issue_url_is_validated_against_project(self) -> None:
        self.assertEqual(
            bmad_issue_tracking.issue_id_from_create_output(
                "https://github.com/example/hermes-client/issues/27\n",
                host="github.com",
                project="example/hermes-client",
            ),
            "27",
        )
        with self.assertRaisesRegex(ValueError, "configured project"):
            bmad_issue_tracking.issue_id_from_create_output(
                "https://github.com/another/repo/issues/27",
                host="github.com",
                project="example/hermes-client",
            )

    def test_recorded_issue_url_is_added_to_indexed_story(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "story-index.yaml"
            index.write_text(
                """schema_version: 1
stories:
  - id: 1-I-2
    title: Render honest turn phases
    horizon: current
""",
                encoding="utf-8",
            )

            self.assertTrue(
                bmad_issue_tracking.record_story_issue_url(
                    "1-i-2-render-honest-turn-phases",
                    "27",
                    host="github.com",
                    project="example/hermes-client",
                    platform="github",
                    index_path=index,
                )
            )
            self.assertIn(
                "github_issue: https://github.com/example/hermes-client/issues/27",
                index.read_text(encoding="utf-8"),
            )

    def test_unindexed_story_does_not_create_an_issue_index(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "not-present.yaml"
            self.assertFalse(
                bmad_issue_tracking.record_story_issue_url(
                    "1-1-start-turn",
                    "27",
                    host="github.com",
                    project="example/hermes-client",
                    platform="github",
                    index_path=index,
                )
            )
            self.assertFalse(index.exists())

    def test_record_refuses_to_overwrite_a_dirty_index(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            index = Path(directory) / "story-index.yaml"
            index.write_text(
                "schema_version: 1\nstories:\n  - id: 1-I-2\n    title: Future story\n",
                encoding="utf-8",
            )
            with (
                patch.object(bmad_issue_tracking, "DEFAULT_STORY_INDEX", index),
                patch.object(
                    bmad_issue_tracking.subprocess,
                    "run",
                    return_value=SimpleNamespace(returncode=1),
                ),
            ):
                with self.assertRaisesRegex(ValueError, "already has local changes"):
                    bmad_issue_tracking.record_story_issue_url(
                        "1-i-2-future-story",
                        "27",
                        host="github.com",
                        project="example/hermes-client",
                        platform="github",
                        index_path=index,
                    )


if __name__ == "__main__":
    unittest.main()
