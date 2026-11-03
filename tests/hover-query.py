#!/usr/bin/env python3
"""The hover card (docs/extensions/v1.1.md, "hover-query"): providers asked when the pointer rests
and with Show Hover, their texts in rank order after the diagnostics at the position, a v1
subscriber's answer, the grace period, the keyboard, and the tooltip kept when nobody answers."""
import unittest

lang = __import__('langfeat-query')

RS = lang.RS     # fn main() {\n    let total = 1;\n    total + 1\n}\n


def hover(l1, c1, l2, c2, text):
    return f'{l1} {c1} {l2} {c2}\n{text}'


class Hover(lang.Lang):
    def test_fenced_code_uses_the_hover_cards_own_surface(self):
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text().replace('[ui]\n',
                          '[ui]\nfollow_system = false\ntheme = turbo-pascal\n'))
        root = self.provider({'hello': 'hello 1 hover-query markdown',
                              'answers': {'hover-query': {'body': hover(0, 0, 0, 0,
                                  '```go\nfunc runCLI() int\n```\n\nRuns the command.')}}},
                             'hover = *.rs\n')
        shot = self.work / 'hover.ppm'
        out = self.run_lang(root, ['hover-at 2 10', 'wait 800', 'print-hover-card', f'shot {shot}'])
        self.assertTrue(any(line.startswith('card=shown') for line in out), out)
        self.assertFalse((0, 85, 85) in lang.host.ppm_colors(shot), 'code adds its own hover tint')

    def two(self, a='alpha text', b='beta text', extra_a=None):
        root = self.work / 'lang'
        spec_a = {'hello': 'hello 1 hover-query', 'answers': {'hover-query': {'body': hover(2, 9, 2, 14, a)}},
                  'run': {'diag': [['diagnostics 1 0 1 24', '2 9 2 14 warning unused\n']]}}
        if extra_a:
            spec_a.update(extra_a)
        self.provider(spec_a, 'hover = *.rs\n', name='alpha', root=root,
                      extra='[commands]\ndiag = Diagnose\n[subscribe]\nhover = *\n')
        self.provider({'hello': 'hello 1 hover-query', 'answers': {'hover-query': {'body': hover(0, 0, 0, 0, b)}}},
                      'hover = *.rs\n', name='beta', root=root)
        return root

    def cards(self, out):
        return [l for l in out if l.startswith('card=')]

    def sections(self, out):
        return [l for l in out if l.startswith('section ')]

    def run_two(self, root, actions):
        return self.run_editor(['wait-ext fake/alpha running', 'wait-ext fake/beta running', 'wait 200', *actions],
                               exts=root, files=('a.rs',))

    def test_diagnostics_first_then_providers_in_rank_order(self):
        root = self.two()
        out = self.run_two(root, ['cmd alpha.diag', 'wait 200', 'hover-at 2 10', 'wait 300', 'wait 400',
                                  'print-hover-card', 'print-tip'])
        card = self.cards(out)
        self.assertTrue(card and card[0].startswith('card=shown kind=pointer line=2 col=10'), out)
        self.assertEqual(self.sections(out), ['section diag: warning: unused', 'section ext fake/alpha: alpha text',
                                              'section ext fake/beta: beta text'], out)
        self.assertIn('tip=', out)              # the card took the tooltip's place
        log = self.lang_log(name='alpha')
        self.assertTrue(any(' hover-query 1 0 2 10 pointer -' in l for l in log), log)
        self.assertFalse(any(l.startswith('0 hover ') for l in log), log)   # hover-query instead of v1's event

    def test_a_slow_provider_keeps_no_elapsed_deadline(self):
        root = self.provider({'hello': 'hello 1 hover-query', 'answers': {'hover-query': {'silent': True}}},
                             'hover = *.rs\n')
        out = self.run_lang(root, ['hover-at 2 10', 'wait 700', 'wait 900', 'print-hover-card',
                                   'print-langfeat-waits'])
        self.assertTrue(any(l.startswith('card=asking') for l in out), out)
        self.assertIn(' hover=-1 ', out[-1])

    def test_a_new_rest_on_the_same_place_asks_again(self):
        root = self.two()
        out = self.run_two(root, ['hover-at 2 10', 'wait 300', 'wait 400', 'print-hover-card', 'move 500 590',
                                  'wait 300', 'wait 400', 'print-hover-card', 'hover-at 2 10', 'wait 300', 'wait 400',
                                  'print-hover-card'])
        cards = self.cards(out)
        self.assertTrue(cards[0].startswith('card=shown'), out)
        self.assertEqual(cards[1], 'card=none', out)
        self.assertTrue(cards[2].startswith('card=shown'), out)
        self.assertEqual(sum(1 for l in self.lang_log(name='alpha') if ' hover-query ' in l), 2)

    def test_a_more_exact_pattern_ranks_first(self):
        root = self.work / 'lang'
        self.provider({'hello': 'hello 1 hover-query', 'answers': {'hover-query': {'body': hover(0, 0, 0, 0, 'A')}}},
                      'hover = *\n', name='alpha', root=root)
        self.provider({'hello': 'hello 1 hover-query', 'answers': {'hover-query': {'body': hover(0, 0, 0, 0, 'Z')}}},
                      'hover = a.rs\n', name='zebra', root=root)
        out = self.run_editor(['wait-ext fake/alpha running', 'wait-ext fake/zebra running', 'wait 200', 'hover-at 2 10',
                               'wait 300', 'wait 500', 'print-hover-card'], exts=root, files=('a.rs',))
        self.assertEqual(self.sections(out), ['section ext fake/zebra: Z', 'section ext fake/alpha: A'], out)

    def test_markdown_renders_selects_and_copies(self):
        root = self.work / 'lang'
        self.provider({'hello': 'hello 1 hover-query markdown',
                       'answers': {'hover-query': {'body': hover(0, 0, 0, 0, '**bold** text')}}},
                      'hover = *.rs\n', name='alpha', root=root)
        out = self.run_editor(['wait-ext fake/alpha running', 'wait 200', 'key ctrl+i', 'wait 300', 'key ctrl+i',
                               'key ctrl+a', 'print-hover-card', 'key ctrl+c', 'key Escape', 'key ctrl+End',
                               'key ctrl+v', 'echo ===', 'print-doc'], exts=root, files=('a.rs',))
        self.assertIn('selected: bold text', out)
        doc = out[out.index('===') + 1:]
        self.assertIn('bold text', '\n'.join(doc), out)

    def test_plain_text_shows_as_it_is(self):
        root = self.work / 'lang'
        self.provider({'hello': 'hello 1 hover-query', 'answers': {'hover-query': {'body': hover(0, 0, 0, 0, '**x** [y]')}}},
                      'hover = *.rs\n', name='alpha', root=root)
        out = self.run_editor(['wait-ext fake/alpha running', 'wait 200', 'key ctrl+i', 'wait 300', 'key ctrl+i',
                               'key ctrl+a', 'print-hover-card'], exts=root, files=('a.rs',))
        self.assertIn('selected: **x** [y]', out)

    def card_actions(self, text, actions, markdown=False):
        root = self.work / 'lang'
        self.provider({'hello': 'hello 1 hover-query' + (' markdown' if markdown else ''),
                       'answers': {'hover-query': {'body': hover(0, 0, 0, 0, text)}}},
                      'hover = *.rs\n', name='alpha', root=root)
        return self.run_editor(['wait-ext fake/alpha running', 'wait 200', 'key ctrl+i', 'wait 300', 'key ctrl+i',
                                *actions], exts=root, files=('a.rs',))

    def test_a_plain_url_keeps_its_characters(self):
        out = self.card_actions('see https://example.com/a_b.c here', ['key ctrl+a', 'print-hover-card'])
        self.assertIn('selected: see https://example.com/a_b.c here', out)

    def test_copied_plain_indentation_is_ordinary_spaces(self):
        out = self.card_actions('one\n    two', ['key ctrl+a', 'key ctrl+c', 'print-hover-card', 'key Escape',
                                                 'key ctrl+End', 'key ctrl+v', 'echo ===', 'print-doc'])
        i = out.index('selected: one')
        self.assertEqual(out[i + 1], '    two', out)       # no no-break spaces
        doc = '\n'.join(out[out.index('===') + 1:])
        self.assertIn('one\n    two', doc)
        self.assertNotIn('\u00a0', doc)

    def test_a_long_code_line_scrolls_sideways(self):
        out = self.card_actions('```\n' + 'x' * 300 + 'END\n```', ['print-hover-card', 'key Right', 'key Right',
                                                                    'print-hover-card', 'key Left', 'key Left',
                                                                    'key Left', 'print-hover-card'], markdown=True)
        side = [l for l in out if l.startswith('sideways=')]
        self.assertEqual(len(side), 3, out)
        pos = [int(l.split('=')[1].split('/')[0]) for l in side]
        most = int(side[0].split('/')[1])
        self.assertGreater(most, 0, side)
        self.assertEqual(pos[0], 0, side)
        self.assertGreater(pos[1], 0, side)
        self.assertEqual(pos[2], 0, side)

    def test_identical_texts_show_once_and_a_v1_answer_joins(self):
        root = self.two(a='same', b='same')
        self.provider({'hello': 'hello 1', 'hover_text': 'from v1'}, 'definition = *.go\n', name='gamma',
                      root=root, extra='[commands]\nstart = Start\n[subscribe]\nhover = *\n')
        out = self.run_editor(['wait-ext fake/alpha running', 'wait-ext fake/beta running', 'cmd gamma.start',
                               'wait 300', 'hover-at 2 10', 'wait 300', 'wait 500', 'print-hover-card'],
                              exts=root, files=('a.rs',))
        self.assertEqual(self.sections(out), ['section ext fake/alpha: same', 'section v1: from v1'], out)

    def test_the_card_stays_on_its_range_and_goes_after_the_grace(self):
        root = self.two()
        out = self.run_two(root, ['hover-at 2 10', 'wait 300', 'wait 400', 'print-hover-card', 'hover-at 2 13',
                                  'wait 600', 'print-hover-card', 'move 500 590', 'wait 100', 'print-hover-card',
                                  'wait 500', 'print-hover-card'])
        card = self.cards(out)
        self.assertTrue(card[0].startswith('card=shown'), out)
        self.assertTrue(card[1].startswith('card=shown kind=pointer line=2 col=10'), out)   # on its range
        self.assertTrue(card[2].startswith('card=shown'), out)    # leaving: the grace
        self.assertEqual(card[3], 'card=none', out)

    def test_show_hover_focuses_and_escape_closes(self):
        root = self.two()
        out = self.run_two(root, ['key ctrl+Home', 'key Down', 'key End', 'key ctrl+i', 'wait 300',
                                  'print-hover-card', 'key ctrl+i', 'print-hover-card', 'key Down',
                                  'key Escape', 'print-hover-card'])
        card = self.cards(out)
        self.assertTrue(card[0].startswith('card=shown kind=invoked line=2 col=19 focused=0'), out)
        self.assertIn('focused=1', card[1])
        self.assertEqual(card[2], 'card=none')
        log = self.lang_log(name='beta')
        self.assertTrue(any(' hover-query 1 0 2 19 invoked -' in l for l in log), log)

    def test_typing_closes_and_nothing_to_show_says_so(self):
        root = self.provider({'hello': 'hello 1 hover-query', 'answers': {'hover-query': {'body': ''}}},
                             'hover = *.rs\n')
        out = self.run_lang(root, ['key ctrl+i', 'wait 300', 'print-hover-card', 'print-toast'])
        self.assertIn('card=none', out)
        self.assertIn('No hover information here', out[-1])
        root2 = self.two()
        out = self.run_two(root2, ['key ctrl+i', 'wait 300', 'print-hover-card', 'type x', 'print-hover-card'])
        card = self.cards(out)
        self.assertTrue(card[0].startswith('card=shown'), out)
        self.assertEqual(card[1], 'card=none')

    def test_next_problem_moves_and_shows_the_card(self):
        diag = '2 9 2 14 warning unused\n3 5 3 10 error bad\n'
        root = self.provider({'hello': 'hello 1', 'run': {'diag': [[f'diagnostics 1 0 2 {len(diag)}', diag]]}},
                             'definition = *.rs\n', extra='[commands]\ndiag = Diagnose\n')
        out = self.run_lang(root, ['cmd lang.diag', 'wait 200', 'key F8', 'wait 100', 'print-state', 'print-hover-card',
                                   'key Escape', 'key F8', 'print-state', 'key Escape', 'key F8', 'print-state',
                                   'key Escape', 'key shift+F8', 'print-state'])
        states = [l for l in out if l.startswith('tabs=')]
        self.assertIn('line=2 col=9', states[0])
        self.assertIn('section diag: warning: unused', out)
        self.assertIn('line=3 col=5', states[1])
        self.assertIn('line=2 col=9', states[2])       # around
        self.assertIn('line=3 col=5', states[3])

if __name__ == '__main__':
    unittest.main()
