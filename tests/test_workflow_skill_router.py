import unittest

from scripts.workflow.skill_router import route_skills


class TestWorkflowSkillRouter(unittest.TestCase):
    def test_route_includes_git_commit(self):
        decision = route_skills(["P0-G2", "P0-G3"])
        selected = decision["selected_skills"]
        self.assertIn("macos-developer", selected)
        self.assertIn("git-commit", selected)
        self.assertIn("app-store-review", selected)


if __name__ == "__main__":
    unittest.main()
