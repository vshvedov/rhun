#!/usr/bin/env python3
"""Claude Code's edits as proposed changes in the Review tab (phase 4 tasks 11 and 12), against the fake CLI
(tests/scripts/fake-claude.py), over the control socket. It imports tests/claude-chat.py and tests/claude-cards.py
for their cases: every rhun gets its own HOME and XDG folders and an environment without CLAUDE* or ANTHROPIC*
variables. The fake applies an allowed edit as the real CLI does (finding 49); rhun itself writes no file. What
was or was not answered is read from the fake's stdin log."""
import importlib.util
import json
import os
from pathlib import Path
import re
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


chat = _load('claude_chat', 'tests/claude-chat.py')
cards = _load('claude_cards', 'tests/claude-cards.py')

NOTES = 'alpha\nbravo\ncharlie\n'
CANCEL_EDIT = 'User cancelled the edit'
CANCEL_WRITE = 'User cancelled the write'
REVERTED = 'User reverted all proposed changes in the diff view'
FOCUS = {'0': 'editor', '6': 'panel', '56': 'box', '8': 'terminal', '2': 'find'}


class OfferCase(cards.CardCase):
    """A conversation whose Edit or Write waits on its card, with its change in the Review tab."""

    def setUp(self):
        super().setUp()
        (self.project / 'notes.txt').write_text(NOTES, encoding='utf-8')

    def offer(self):
        """print-agent-offer as a dict (empty without an offer)."""
        line = self.command('print-agent-offer').strip()
        if line == 'offer=none':
            return {}
        return dict(re.findall(r'(\w+)=(.*?)(?= \w+=|$)', line))

    def review(self):
        return self.command('print-review')

    def state(self):
        return dict(re.findall(r'(\w+)=(\S*)', self.command('print-state')))

    def focus(self):
        return FOCUS.get(self.state().get('focus'), self.state().get('focus'))

    def tabs(self):
        return self.command('print-tabs')

    def decisions(self):
        """The answers to permission requests: each response whose payload has a behavior."""
        out = []
        for m in self.stdin():
            if m.get('type') != 'control_response':
                continue
            inner = (m.get('response') or {}).get('response')
            if isinstance(inner, dict) and 'behavior' in inner:
                out.append(inner)
        return out

    def until_offer(self):
        return self.until(lambda: self.offer(), 'the offer')

    def until_decided(self, n=1):
        return self.until(lambda: len(self.decisions()) >= n and self.decisions(), 'the answer')

    def again(self):
        """A second rhun in the same test: the fake's log starts again."""
        self.stop()
        if self.fake_log.exists():
            self.fake_log.unlink()

    def edit(self, prompt='editfile notes.txt bravo BRAVO', lock=0, **start):
        self.ask(prompt, lock=lock, **start)
        return self.until_offer()


class OfferTest(OfferCase):
    """Task 11: the change in the Review tab, tied to the card both ways (UI 4.8; IDE 2.2, 2.3)."""

    def test_an_edit_opens_in_the_review_tab(self):
        offer = self.edit()
        self.assertEqual(offer['label'], 'Claude Code: notes.txt')
        self.assertEqual(offer['file'], 'notes.txt')
        self.assertEqual((offer['changes'], offer['decided'], offer['edited'], offer['done']), ('1', '0', '0', '0'))
        review = self.review()
        self.assertIn('label=Claude Code: notes.txt done=0 offer=1', review)
        self.assertIn('path=notes.txt +1 -1 state=pending', review)
        self.assertIn('link Review the change', self.card()[1])
        self.assertEqual(self.decisions(), [])

    def test_typing_as_the_card_appears_decides_nothing(self):
        self.start()
        self.command('agent-new claude')
        self.command('agent-prompt editlater 300 notes.txt bravo BRAVO')
        self.command('agent-focus box')
        typed = ''
        end = time.monotonic() + 1.2
        while time.monotonic() < end:
            self.command('type abc')
            self.command('key a')
            self.command('key r')
            typed += 'abcar'
            time.sleep(0.02)
            if self.offer() and time.monotonic() > end - 0.8:
                break
        offer = self.until_offer()
        self.assertEqual(offer['done'], '0')
        self.assertEqual(self.focus(), 'box')
        self.assertIn(typed, self.command('print-agent-input'))
        self.assertEqual(self.decisions(), [])
        # past the lock, the user goes into the tab: its key accepts
        time.sleep(0.6)
        self.command('agent-focus editor')
        self.assertIn('shown=1', self.command('print-agent-offer'))
        self.command('key a')
        answers = self.until_decided()
        self.assertEqual(len(answers), 1)
        self.assertEqual(answers[0]['behavior'], 'allow')

    def test_the_tab_never_takes_the_keys(self):
        # from the box and from the panel the tab is shown, the keys stay in the panel (the card's own focus
        # rule may take them from an idle box: agentcard_shown); from a document and its find field it waits
        # behind, the keys stay there
        for where, shown, keys in (('box', '1', ('box', 'panel')), ('panel', '1', ('panel',)),
                                   ('editor', '0', ('editor',)), ('find', '0', ('find',))):
            with self.subTest(where=where):
                self.again()
                self.start()
                self.command('open ' + str(self.project / 'notes.txt'))
                self.command('agent-timing card=0')
                self.command('agent-new claude')
                self.command('agent-prompt editlater 300 notes.txt bravo BRAVO')
                if where == 'find':
                    self.command('agent-focus editor')
                    self.command('key ctrl+f')
                else:
                    self.command('agent-focus ' + where)
                before = self.focus()
                offer = self.until_offer()
                self.assertEqual(offer['shown'], shown)
                self.assertIn(self.focus(), keys, before)
                self.assertEqual(self.decisions(), [])

    def test_the_tab_waits_behind_while_the_keys_are_in_a_document(self):
        self.start()
        self.command('open ' + str(self.project / 'notes.txt'))
        self.command('agent-timing card=0')
        self.command('agent-new claude')
        self.command('agent-prompt editlater 300 notes.txt bravo BRAVO')
        self.command('agent-focus editor')
        offer = self.until_offer()
        self.assertEqual(offer['shown'], '0')
        self.assertEqual(self.focus(), 'editor')
        self.command('key x')               # a key typed in the document goes to the document
        self.assertEqual(self.decisions(), [])
        self.command('agent-card review')   # the card's link shows it, the keys stay
        self.until(lambda: self.offer().get('shown') == '1', 'the tab shown')

    def test_the_tabs_buttons_wait_for_the_cards_lock(self):
        self.edit(lock=500)
        self.command('review accept all')
        time.sleep(0.2)
        self.assertEqual(self.offer()['done'], '0')
        self.assertEqual(self.decisions(), [])
        time.sleep(0.5)
        self.command('review accept all')
        answers = self.until_decided()
        self.assertEqual(answers[0]['behavior'], 'allow')

    def test_yes_on_the_card_allows_with_the_requests_own_input(self):
        self.edit()
        self.command('agent-card 1')
        answer = self.until_decided()[0]
        self.assertEqual(answer['updatedInput'], {'file_path': str(self.project / 'notes.txt'),
                                                  'old_string': 'bravo', 'new_string': 'BRAVO',
                                                  'replace_all': False})
        self.command('wait-agent ready')
        self.assertEqual((self.project / 'notes.txt').read_text(), 'alpha\nBRAVO\ncharlie\n')
        self.until(lambda: 'offer=1' not in self.review(), 'the tab closed')

    def test_accept_in_the_tab_is_the_cards_yes(self):
        self.edit()
        self.command('review accept all')
        answer = self.until_decided()[0]
        self.assertEqual(answer['behavior'], 'allow')
        self.assertEqual(answer['updatedInput']['new_string'], 'BRAVO')
        self.command('wait-agent ready')
        self.assertEqual((self.project / 'notes.txt').read_text(), 'alpha\nBRAVO\ncharlie\n')
        self.until(lambda: 'offer=1' not in self.review(), 'the tab closed')
        self.assertEqual(len(self.decisions()), 1)

    def test_ctrl_enter_in_the_tab_accepts(self):
        self.edit()
        self.command('agent-focus editor')
        self.command('key ctrl+Return')
        self.assertEqual(self.until_decided()[0]['behavior'], 'allow')

    def test_reject_in_the_tab_denies_with_the_extensions_words(self):
        self.edit()
        self.command('review reject all')
        answer = self.until_decided()[0]
        self.assertEqual((answer['behavior'], answer['message'], answer['interrupt']), ('deny', CANCEL_EDIT, True))
        self.again()
        self.edit('writefile w.txt hello')
        self.command('review reject all')
        answer = self.until_decided()[0]
        self.assertEqual((answer['behavior'], answer['message'], answer['interrupt']), ('deny', CANCEL_WRITE, True))
        self.assertFalse((self.project / 'w.txt').exists())

    def test_closing_the_tab_denies(self):
        self.edit()
        self.command('agent-focus editor')
        self.command('cmd close_tab')
        answer = self.until_decided()[0]
        self.assertEqual((answer['behavior'], answer['message'], answer['interrupt']), ('deny', CANCEL_EDIT, True))
        self.assertEqual((self.project / 'notes.txt').read_text(), NOTES)

    def test_the_cards_no_is_as_before(self):
        self.edit()
        self.assertEqual(self.buttons()[-1], 'No')
        self.command('agent-card %d' % len(self.buttons()))
        answer = self.until_decided()[0]
        self.assertEqual(answer['behavior'], 'deny')
        self.assertTrue(answer['message'].startswith("The user doesn't want to proceed"))
        self.until(lambda: 'offer=1' not in self.review(), 'the tab closed')

    def test_a_write_of_a_new_file_and_of_an_existing_one(self):
        offer = self.edit('writefile w.txt hello')
        self.assertEqual(offer['label'], 'Claude Code: w.txt')
        self.assertIn('path=w.txt +1 -0 state=pending', self.review())
        self.command('review accept all')
        self.until_decided()
        self.command('wait-agent ready')
        self.assertEqual((self.project / 'w.txt').read_text(), 'hello')
        self.again()
        offer = self.edit('writefile notes.txt changed')
        self.assertIn('path=notes.txt +1 -3 state=pending', self.review())

    def test_old_text_that_is_not_in_the_file(self):
        offer = self.edit('editfile notes.txt delta DELTA')
        self.assertEqual(offer['label'], 'Claude Code: notes.txt (edited text only)')
        self.assertIn('+1 -1', self.review())

    def test_a_file_outside_the_project(self):
        outside = self.work / 'outside.txt'
        outside.write_text('one\ntwo\n', encoding='utf-8')
        offer = self.edit('editjs ' + json.dumps({'file_path': str(outside), 'old_string': 'two',
                                                  'new_string': 'TWO'}))
        self.assertEqual(offer['label'], 'Claude Code: outside.txt (file not read)')
        self.assertIn('+1 -1', self.review())

    def test_a_crlf_file_keeps_its_line_ends(self):
        (self.project / 'crlf.txt').write_bytes(b'one\r\ntwo\r\nthree\r\n')
        self.edit('editfile crlf.txt two TWO')
        self.assertIn('path=crlf.txt +1 -1 state=pending', self.review())
        self.command('review accept all')
        self.until_decided()
        self.command('wait-agent ready')
        self.assertEqual((self.project / 'crlf.txt').read_bytes(), b'one\r\nTWO\r\nthree\r\n')

    def test_replace_all(self):
        (self.project / 'r.txt').write_text('a x\nb x\nc x\n', encoding='utf-8')
        self.edit('editjs ' + json.dumps({'file_path': 'r.txt', 'old_string': 'x', 'new_string': 'y',
                                          'replace_all': True}))
        self.assertIn('path=r.txt +3 -3 state=pending', self.review())

    def test_rhun_writes_no_file(self):
        path = self.project / 'notes.txt'
        before = (path.read_bytes(), os.stat(path).st_mtime_ns)
        self.edit('editnowrite notes.txt bravo BRAVO')
        self.command('review accept all')
        self.until_decided()
        self.command('wait-agent ready')
        self.assertEqual((path.read_bytes(), os.stat(path).st_mtime_ns), before)

    def test_one_answer_however_it_is_decided(self):
        self.edit()
        self.command('review accept all')
        self.command('agent-card 1')
        self.command('wait-agent ready')
        time.sleep(0.3)
        self.assertEqual(len(self.decisions()), 1)
        self.again()
        self.edit()
        self.command('review reject all')
        self.command('agent-focus editor')
        self.command('cmd close_tab')
        time.sleep(0.5)
        self.assertEqual(len(self.decisions()), 1)

    def test_only_the_head_request_has_an_offer(self):
        self.edit('edit2 notes.txt alpha ALPHA charlie CHARLIE')
        self.assertIn('+1 -1', self.review())
        self.assertEqual(self.review().count('offer=1'), 1)
        self.command('review accept all')
        self.until(lambda: len(self.decisions()) == 1 and 'offer=1' in self.review()
                   and self.offer().get('done') == '0', 'the second offer')
        self.assertEqual(self.review().count('offer=1'), 1)
        self.command('review accept all')
        self.until_decided(2)
        self.command('wait-agent ready')
        self.assertEqual((self.project / 'notes.txt').read_text(), 'ALPHA\nbravo\nCHARLIE\n')

    def test_the_card_with_a_change_fits(self):
        self.edit()
        fit = self.command('print-agent-card-fit')
        self.assertIn('size=13 w=380 ', fit)
        self.assertIn('r', fit)


class OfferLifeTest(OfferCase):
    """Task 11: the offer goes with its request, its process, its conversation; nothing is sent then."""

    def gone(self):
        self.until(lambda: 'offer=1' not in self.review(), 'the tab closed')
        self.assertNotIn('Claude Code: notes.txt', self.tabs())

    def test_a_withdrawn_request_closes_its_tab(self):
        self.edit()
        self.command('agent-stop')
        self.gone()
        self.assertEqual(self.decisions(), [])

    def test_the_end_of_the_process_closes_its_tab(self):
        self.edit()
        self.command('agent-release')
        self.gone()
        self.assertEqual(self.decisions(), [])

    def test_quit_with_an_offer_open(self):
        self.edit()
        self.quit()
        self.assertEqual(self.decisions(), [])

    def test_an_answer_after_the_tab_closed_by_the_user_is_the_deny(self):
        self.edit()
        self.command('agent-focus editor')
        self.command('cmd close_tab')
        self.until_decided()
        self.command('agent-card 1')
        time.sleep(0.3)
        self.assertEqual(len(self.decisions()), 1)


if __name__ == '__main__':
    unittest.main()
