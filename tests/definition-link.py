#!/usr/bin/env python3
"""Modifier-hover confirms definitions without navigating, and paints only live results."""
import unittest

links = __import__('document-links')
lang = __import__('langfeat-query')


class DefinitionLink(links.DocumentLinks):
    # The inherited document-link navigation tests also run alongside these checks.
    def definition_provider(self, answer):
        self.definition_cases = getattr(self, 'definition_cases', 0) + 1
        return self.provider({'hello': 'hello 1 definition query-stream',
                              'answers': {'definition': answer}}, 'definition = *.rs\n',
                             root=self.work / f'lang-{self.definition_cases}')

    def test_modifier_confirms_underlines_and_releases_without_moving_caret(self):
        root = self.definition_provider({'body': '1\n' + lang.loc('{path}', 2, 9, 2, 14, 'total')})
        x, y = map(int, self.point(root, 2, 10))
        before, held, released = [self.work / (n + '.ppm') for n in ('before', 'held', 'released')]
        out = self.run_lang(root, [f'move {x} {y}', 'wait 50', 'print-definition-link',
                                   f'shot {before}', 'modifiers ctrl', 'wait 150',
                                   'print-definition-link', f'shot {held}', 'print-state',
                                   'modifiers none', 'wait 50', 'print-definition-link',
                                   f'shot {released}', 'print-state'])
        self.assertEqual([s for s in out if s.startswith('definition-link=')],
                         ['definition-link=none', 'definition-link=found', 'definition-link=none'], out)
        self.assertEqual(sum(' definition ' in s and not s.startswith('0 ') for s in self.lang_log()), 1)
        self.assertTrue(all(' line=1 col=1 sel=0' in s for s in out if s.startswith('tabs=')), out)
        # The underline appears below the hovered word and disappears on modifier release.
        def pixels(path):
            header, size, maximum, data = path.read_bytes().split(b'\n', 3)
            width = int(size.split()[0])
            return lambda px, py: data[3 * (py * width + px):3 * (py * width + px) + 3]
        a, b, c = map(pixels, (before, held, released))
        changed = [(px, py) for py in range(y, y + 15) for px in range(x - 10, x + 50)
                   if a(px, py) != b(px, py)]
        self.assertTrue(changed, 'no visual feedback below the hovered symbol')
        for px, py in changed:
            self.assertEqual(a(px, py), c(px, py))

    def test_empty_or_malformed_answer_does_not_make_a_link(self):
        for body in ('0\n', '1\n', '1\n1 1 1 2 3 0\nrel'):
            with self.subTest(body=body):
                root = self.definition_provider({'body': body})
                out = self.run_lang(root, ['hover-at 2 10', 'modifiers ctrl', 'wait 150',
                                           'print-definition-link', 'print-state'])
                self.assertIn('definition-link=none', out)
                self.assertTrue(any(' line=1 col=1 sel=0' in s for s in out if s.startswith('tabs=')), out)

    def test_moving_within_one_word_reuses_the_confirmation(self):
        root = self.definition_provider({'body': '1\n' + lang.loc('{path}', 2, 9, 2, 14, 'total')})
        out = self.run_lang(root, ['hover-at 2 10', 'modifiers ctrl', 'wait 150',
                                   'hover-at 2 12', 'wait 150', 'print-definition-link'])
        self.assertIn('definition-link=found', out)
        self.assertEqual(sum(' definition ' in s and not s.startswith('0 ') for s in self.lang_log()), 1)

    def test_leaving_cancels_and_late_answers_cannot_restore_a_link(self):
        root = self.definition_provider({'delay': .3, 'body': '1\n' + lang.loc('{path}', 2, 9, 2, 14, 'total')})
        out = self.run_lang(root, ['hover-at 2 10', 'modifiers ctrl', 'wait 50',
                                   'move 950 590', 'wait 450', 'print-definition-link', 'print-state'])
        self.assertIn('definition-link=none', out)
        self.assertTrue(any(s.startswith('0 cancel ') for s in self.lang_log()), self.lang_log())
        self.assertTrue(any(' line=1 col=1 sel=0' in s for s in out if s.startswith('tabs=')), out)

    def test_edits_retire_a_pending_confirmation(self):
        root = self.definition_provider({'delay': .3, 'body': '1\n' + lang.loc('{path}', 2, 9, 2, 14, 'total')})
        out = self.run_lang(root, ['hover-at 2 10', 'modifiers ctrl', 'wait 50',
                                   'type x', 'wait 450', 'print-definition-link'])
        self.assertIn('definition-link=none', out)

    def test_partial_results_confirm_even_when_the_final_answer_is_empty(self):
        root = self.definition_provider({'parts': [['1\n' + lang.loc('{path}', 2, 9, 2, 14, 'total'), .05]],
                                         'body': '0\n'})
        out = self.run_lang(root, ['hover-at 2 10', 'modifiers ctrl', 'wait 200',
                                   'print-definition-link', 'print-state'])
        self.assertIn('definition-link=found', out)
        self.assertTrue(any(' line=1 col=1 sel=0' in s for s in out if s.startswith('tabs=')), out)

    def test_wrapped_rows_get_the_underline_at_the_pointer(self):
        root = self.definition_provider({'body': '1\n' + lang.loc('{path}', 1, 1, 1, 3, 'target')})
        text = 'fn main() {\n    let values = [' + '1, ' * 120 + ']; let total = 1;\n}\n'
        (self.proj / 'a.rs').write_text(text)
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text().replace('[editor]\n', '[editor]\nword_wrap = true\n'))
        col = text.splitlines()[1].index('total') + 2
        out = self.run_lang(root, [f'print-xy 2 {col}'])
        x, y = map(int, next(s for s in out if len(s.split()) == 2 and all(v.isdigit() for v in s.split())).split())
        before, held = self.work / 'wrap-before.ppm', self.work / 'wrap-held.ppm'
        out = self.run_lang(root, [f'move {x + 2} {y}', f'shot {before}', 'modifiers ctrl',
                                   'wait 150', 'print-definition-link', f'shot {held}'])
        self.assertIn('definition-link=found', out)
        def data(path):
            _, size, _, pixels = path.read_bytes().split(b'\n', 3)
            width = int(size.split()[0])
            return lambda px, py: pixels[3 * (py * width + px):3 * (py * width + px) + 3]
        a, b = data(before), data(held)
        self.assertTrue(any(a(px, py) != b(px, py) for py in range(y, y + 15)
                            for px in range(x - 5, x + 30)), 'wrapped symbol was not underlined')

    def test_withdrawing_definition_support_clears_the_confirmation(self):
        root = self.provider({'hello': 'hello 1 definition provider-scope',
                              'answers': {'definition': {'body': '1\n' + lang.loc('{path}', 2, 9, 2, 14, 'total')}},
                              'run': {'withdraw': [['provides definition -', '']]}},
                             'definition = *.rs\n', extra='[commands]\nwithdraw = Withdraw\n')
        out = self.run_lang(root, ['hover-at 2 10', 'modifiers ctrl', 'wait 150',
                                   'print-definition-link', 'cmd lang.withdraw', 'wait 150',
                                   'print-definition-link'])
        self.assertEqual([s for s in out if s.startswith('definition-link=')],
                         ['definition-link=found', 'definition-link=none'], out)


if __name__ == '__main__':
    unittest.main()
