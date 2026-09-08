import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "dotfiles/bin/.local/bin/agent"


def load_agent():
    loader = importlib.machinery.SourceFileLoader("agent_cli_resolution", str(AGENT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class AgentResolutionTests(unittest.TestCase):
    def test_exact_name_wins_but_shared_cwd_is_rejected(self):
        agent = load_agent()
        agent.all_sessions = lambda: [
            ("lovable", "/tmp/lovable.sock", {"name": "worker", "cwd": "/repo"}),
            ("personal", "/tmp/personal.sock", {"name": "nixos", "cwd": "/repo"}),
        ]

        self.assertEqual(agent.resolve("nixos")[2]["name"], "nixos")
        with self.assertRaisesRegex(SystemExit, "ambiguous cwd.*lovable/worker.*personal/nixos"):
            agent.resolve("", cwd_path="/repo")


if __name__ == "__main__":
    unittest.main()
