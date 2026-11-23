#!/usr/bin/env python3
"""Claude Code's rich cards in the agents panel (phase 2: permission, questions, plan review in a tab, the
CLI's dialogs), against the fake CLI (tests/scripts/fake-claude.py), over the control socket. It imports
tests/claude-chat.py for its cases: every rhun gets its own HOME and XDG folders, an environment without
CLAUDE* or ANTHROPIC* variables, and a config whose [claude] section starts the fake. Rules a test saves
go to destination session, or localSettings inside its temporary project: never the user's own."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location('claude_chat', ROOT / 'tests/claude-chat.py')
chat = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(chat)


class CardSeamTest(chat.DrivenCase):
    """The seam the cards come through (their tasks add the cards themselves)."""

    def test_a_request_keeps_the_simple_card_until_rich_cards_come(self):
        self.start()
        self.chat('tool', 'waiting')
        self.assertIn(' requests=1 ', self.live())
        self.assertIn('card=Allow this bash command? ', self.command('print-agent-input'))
        self.command('agent-card 1')
        self.command('wait-agent ready')
        self.assertIn(' requests=0 ', self.live())


if __name__ == '__main__':
    unittest.main()
