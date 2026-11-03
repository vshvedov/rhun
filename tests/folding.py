#!/usr/bin/env python3
"""Folding (editor presentation stage 5): indentation ranges, the fold commands and keys, the fold
lane and the pill, caret motion over folds, folds that open when the caret lands inside, edits that
remove folds, line commands on folded headers, sessions and closed tabs, vim, and the view that
scrolls by rows. Stage 6: a folding provider (feature folding-ranges, the fake extension
tests/ext/present.py answering) whose ranges replace indentation's."""
import json
from pathlib import Path
import unittest

pres = __import__('presentation')
host = pres.host

NESTED = '''fn a() {
    if x {
        one();
        two();
    }

    three();
}

fn b() {
    four();
}
'''


class FoldBase(pres.Base):
    def setUp(self):
        super().setUp()
        (self.proj / 'n.rs').write_text(NESTED, encoding='utf-8')

    def run_f(self, actions, files=('n.rs',), **kw):
        return self.run_p(actions, files=files, **kw)

    def folds(self, out):
        return [l for l in out if l.startswith('fold ')]

    def state(self, out, i=0):
        return [l for l in out if l.startswith('tabs=')][i]


class Folding(FoldBase):

    def test_fold_and_unfold_by_indentation(self):
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'print-present folds', 'print-viewport',
                          'key Down', 'key Down', 'cmd fold', 'print-present folds',
                          'cmd unfold', 'print-present folds'])
        # "fn a() {" folds through "three();" (the closing brace stays); the blank line inside counts
        self.assertEqual(self.folds(out)[0], 'fold 1-7')
        self.assertIn('hidden 6', out)
        self.assertTrue(any(l.startswith('view mode=rows top=1 ') for l in out), out)
        # Down twice from line 1: line 8 ("}"), then 9 (blank): nothing to fold or open there
        self.assertEqual(self.folds(out)[1:], ['fold 1-7', 'fold 1-7'])

    def test_bracket_folding_unindented(self):
        code = 'function calculateTotal() {\n$subtotal = 100;\n$tax = 10;\nreturn $subtotal + $tax;\n}\n'
        (self.proj / 'calc.php').write_text(code, encoding='utf-8')
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'print-present folds',
                          'cmd unfold', 'print-present folds'], files=('calc.php',))
        # Enclosed lines inside { ... } fold, leaving closing brace on line 5 visible
        self.assertEqual(self.folds(out)[0], 'fold 1-4')
        self.assertEqual(self.folds(out)[1:], [])

    def test_bracket_folding_nested(self):
        code = 'function calc() {\nif ($x) {\n$a = 1;\n}\nreturn $a;\n}\n'
        (self.proj / 'nested.php').write_text(code, encoding='utf-8')
        out = self.run_f(['key ctrl+Home', 'key Down', 'cmd fold', 'print-present folds',
                          'key ctrl+Home', 'cmd fold', 'print-present folds'], files=('nested.php',))
        f = self.folds(out)
        self.assertEqual(f[0], 'fold 2-3')
        self.assertEqual(f[1:], ['fold 1-5', 'fold 2-3'])

    def test_bracket_folding_arrays_and_calls(self):
        code = 'items = [\n1,\n2,\n]\nfunc(\na,\nb\n)\n'
        (self.proj / 'data.js').write_text(code, encoding='utf-8')
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'print-present folds',
                          'key Down', 'key Down', 'key Down', 'key Down', 'cmd fold', 'print-present folds'],
                         files=('data.js',))
        f = self.folds(out)
        self.assertEqual(f[0], 'fold 1-3')
        self.assertEqual(f[1:], ['fold 1-3', 'fold 5-7'])

    def test_bracket_folding_strings_and_comments_ignored(self):
        code = 'function calc() {\n// a line with {\nlet s = "string { with } braces";\nreturn 10;\n}\n'
        (self.proj / 'sample.js').write_text(code, encoding='utf-8')
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'print-present folds'], files=('sample.js',))
        self.assertEqual(self.folds(out), ['fold 1-4'])

    def test_bracket_folding_gutter_click(self):
        code = 'function calc() {\n$a = 1;\n$b = 2;\nreturn $a + $b;\n}\n'
        (self.proj / 'gutter.php').write_text(code, encoding='utf-8')
        out = self.run_f(['print-xy 1 1'] + [f'print-hit {x} 86' for x in range(0, 60, 2)], files=('gutter.php',))
        xs = [x for x, l in zip(range(0, 60, 2), out[1:]) if l.startswith('fold-lane ')]
        self.assertTrue(xs, out)
        y = int(out[0].split()[1])
        # Clicking the fold lane on line 1 collapses the PHP function
        out = self.run_f([f'click {xs[0] + 2} {y}', 'print-present folds'], files=('gutter.php',))
        self.assertEqual(self.folds(out), ['fold 1-4'])
        # Clicking again unfolds it
        out = self.run_f([f'click {xs[0] + 2} {y}', f'click {xs[0] + 2} {y}', 'print-present folds'], files=('gutter.php',))
        self.assertEqual(self.folds(out), [])

    def test_innermost_range_holding_the_caret(self):
        out = self.run_f(['key ctrl+Home', 'key Down', 'key Down', 'cmd fold', 'print-present folds',
                          'print-state', 'cmd fold', 'print-present folds'])
        f = self.folds(out)
        self.assertEqual(f[0], 'fold 2-4')          # "if x {" holds line 3
        self.assertIn('line=2 col=', self.state(out))
        self.assertEqual(f[1:], ['fold 1-7', 'fold 2-4'])

    def test_fold_all_levels_and_unfold_all(self):
        out = self.run_f(['cmd fold_all', 'print-present folds', 'cmd unfold_all', 'print-present folds',
                          'cmd fold_level_2', 'print-present folds'])
        self.assertEqual(self.folds(out)[:3], ['fold 1-7', 'fold 2-4', 'fold 10-11'])
        self.assertEqual(self.folds(out)[3:], ['fold 2-4'])

    def test_caret_steps_over_folds(self):
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'key Down', 'print-state', 'key Up', 'print-state',
                          'key End', 'key Right', 'print-state', 'key Left', 'print-state',
                          'print-present folds'])
        self.assertIn('line=8 col=1 ', self.state(out, 0))
        self.assertIn('line=1 col=1 ', self.state(out, 1))
        self.assertIn('line=8 col=1 ', self.state(out, 2))
        self.assertIn('line=1 col=9 ', self.state(out, 3))
        self.assertEqual(self.folds(out), ['fold 1-7'])

    def test_caret_landing_inside_opens_the_fold(self):
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'cmd goto_line', 'type 4', 'key Return',
                          'print-state', 'print-present folds'])
        self.assertIn('line=4 ', self.state(out))
        self.assertEqual(self.folds(out), [])

    def test_edits_keep_or_remove_folds(self):
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'key End', 'type  ', 'print-present folds',
                          'key ctrl+Home', 'key Return', 'print-present folds',
                          'key End', 'key Delete', 'print-present folds'])
        f = self.folds(out)
        self.assertEqual(f[0], 'fold 1-7')          # typed at the header's end
        self.assertEqual(f[1], 'fold 2-8')          # a line above: it moves down
        self.assertEqual(f[2:], [])                 # the header's line feed deleted

    def test_line_commands_take_the_hidden_lines(self):
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'cmd duplicate_line', 'print-doc'])
        doc = '\n'.join(out)
        self.assertEqual(doc.count('three();'), 2)
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'cmd delete_line', 'print-doc'])
        doc = '\n'.join(out)
        self.assertNotIn('three();', doc)
        self.assertIn('four();', doc)

    def test_lane_chevrons_and_pill(self):
        out = self.run_f(['print-xy 1 1'] + [f'print-hit {x} 86' for x in range(0, 60, 2)])
        lane = [int(l.split()[1]) for l in out if l.startswith('fold-lane ')]
        xs = [x for x, l in zip(range(0, 60, 2), out[1:]) if l.startswith('fold-lane ')]
        self.assertTrue(xs, out)
        y = int(out[0].split()[1])
        out = self.run_f([f'click {xs[0] + 2} {y}', 'print-present folds', 'print-xy 1 9'])
        self.assertEqual(self.folds(out), ['fold 1-7'])
        x9, _ = map(int, out[-1].split())
        # the pill after "fn a() {" unfolds
        out = self.run_f([f'click {xs[0] + 2} {y}', f'print-hit {x9 + 12} {y}', f'click {x9 + 12} {y}',
                          'print-present folds'])
        self.assertIn('inlay fold 1 9', out)
        self.assertEqual(self.folds(out), [])
        path = self.work / 'lane.ppm'
        self.run_f(['cmd fold_all', f'move 4 {y}', f'shot {path}'])
        self.assertTrue(path.exists())

    def test_folds_survive_sessions_and_closed_tabs(self):
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text().replace('restore_session = false', 'restore_session = true'))
        self.run_f(['key ctrl+Home', 'cmd fold', 'key ctrl+End', 'cmd fold_level_1'])
        out = self.run_p(['wait 200', 'print-present folds'], files=())
        self.assertEqual(self.folds(out), ['fold 1-7', 'fold 10-11'])
        out = self.run_f(['cmd close_tab', 'cmd reopen_closed_tab', 'print-present folds'])
        self.assertEqual(self.folds(out), ['fold 1-7', 'fold 10-11'])

    def test_vim_fold_commands(self):
        out = self.run_f(['cmd toggle_vim', 'key ctrl+Home', 'type zc', 'print-present folds', 'type j',
                          'print-state', 'type k', 'type zo', 'print-present folds', 'type zM',
                          'print-present folds', 'type zR', 'print-present folds', 'type za',
                          'print-present folds', 'cmd toggle_vim'])
        f = self.folds(out)
        self.assertEqual(f[0], 'fold 1-7')
        self.assertIn('line=8 ', self.state(out))
        self.assertEqual(f[1:4], ['fold 1-7', 'fold 2-4', 'fold 10-11'])
        self.assertEqual(f[4:], ['fold 1-7'])

    def test_folding_off(self):
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text() + '[editor]\nfolding = false\n')
        out = self.run_f(['key ctrl+Home', 'cmd fold', 'print-present folds'] +
                         [f'print-hit {x} 86' for x in range(0, 60, 2)])
        self.assertEqual(self.folds(out), [])
        self.assertFalse(any(l.startswith('fold-lane') for l in out))

    def test_scroll_without_scroll_past_end(self):
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text() + '[editor]\nscroll_past_end = false\n')
        (self.proj / 'big.rs').write_text(''.join(f'x{i}();\n' for i in range(300)), encoding='utf-8')
        out = self.run_p(['move 500 300', 'scroll 40', 'print-viewport', 'cmd goto_line', 'type 250',
                          'key Return', 'print-viewport'], files=('big.rs',))
        tops = [int(l.split('top=')[1].split()[0]) for l in out if l.startswith('view ')]
        self.assertGreater(tops[0], 1)
        self.assertGreater(tops[1], 200)

    def test_folding_off_restores_and_hides_nothing(self):
        config = self.work / 'config/rhun/config'
        config.write_text(config.read_text().replace('restore_session = false', 'restore_session = true'))
        self.run_f(['key ctrl+Home', 'cmd fold'])
        config.write_text(config.read_text() + '[editor]\nfolding = false\n')
        out = self.run_p(['wait 200', 'print-present folds', 'key ctrl+Home', 'key Down', 'print-state'], files=())
        self.assertEqual(self.folds(out), [])
        self.assertIn('line=2 ', self.state(out))

    def test_scroll_by_rows_over_folds(self):
        (self.proj / 'big.rs').write_text(''.join(
            f'fn f{i}() {{\n' + ''.join(f'    x{j}();\n' for j in range(20)) + '}\n' for i in range(50)),
            encoding='utf-8')
        out = self.run_p(['print-viewport', 'cmd fold_all', 'print-viewport', 'move 500 300', 'scroll 105',
                          'print-viewport', 'print-scroll'], files=('big.rs',))
        views = [l for l in out if l.startswith('view ')]
        before = int(views[0].split('content=')[1])
        after = int(views[1].split('content=')[1])
        self.assertLess(after, before // 5)          # 50 folds of 20 lines: 101 rows left of 1101
        top = int(views[2].split('top=')[1].split()[0])
        self.assertIn((top - 1) % 22, (0, 21))       # a header or a closing brace: no folded line
        self.assertGreater(top, 22)


RANGES = '3\n1 8 - 0\n2 5 comment 0\n10 12 region 4\nbody'


class ProviderFolding(FoldBase):
    """A folding provider (feature folding-ranges): its ranges replace indentation's."""
    def setUp(self):
        super().setUp()
        ini = self.exts / 'rhun-tests/present/extension.ini'
        ini.write_text(ini.read_text() + '[provides]\nfolding = *.rs\n', encoding='utf-8')
        self.env['PRESENT_HELLO'] = 'hello 1 folding-ranges'
        self.answer(RANGES)

    def answer(self, body):
        path = self.exts / 'rhun-tests/present/answers.json'
        path.write_text(json.dumps({'folding-ranges': ['ok {ID} {LEN}', body]}), encoding='utf-8')
        self.env['PRESENT_ANSWERS'] = path.as_posix()

    def asked(self):
        if not self.plog.exists():
            return []
        return [l.split(' ', 1)[1] for l in self.plog.read_text(errors='replace').splitlines()
                if ' folding-ranges ' in l and l.split(' ')[0] != '0']

    def ranges(self, out):
        return [l for l in out if l.startswith('range')]

    def test_provider_ranges_replace_indentation(self):
        out = self.run_f(self.start() + ['print-present ranges', 'key ctrl+Home', 'cmd fold',
                                         'print-present folds', 'cmd unfold_all', 'cmd fold_all',
                                         'print-present folds'])
        self.assertEqual(self.ranges(out), ['ranges present', 'range 1-8 kind=0', 'range 2-5 kind=2',
                                            'range 10-12 kind=1 text=body'])
        # the narrowest range holding line 1 (indentation would fold 1-7)
        self.assertEqual(self.folds(out), ['fold 1-8', 'fold 1-8', 'fold 2-5', 'fold 10-12 text=body'])
        self.assertEqual(len(self.asked()), 1, self.asked())
        self.assertRegex(self.asked()[0], r'^folding-ranges \d+ \d+$')

    def test_ranges_follow_edits_until_the_next_answer(self):
        out = self.run_f(self.start() + ['key ctrl+Home', 'key Return', 'print-present ranges', 'wait 900',
                                         'print-present ranges'])
        r = self.ranges(out)
        self.assertEqual(r[:4], ['ranges present', 'range 2-9 kind=0', 'range 3-6 kind=2',
                                 'range 11-13 kind=1 text=body'])
        # asked again after the edit: the same answer, now about the new text
        self.assertEqual(r[4:], ['ranges present', 'range 1-8 kind=0', 'range 2-5 kind=2',
                                 'range 10-12 kind=1 text=body'])
        asked = self.asked()
        self.assertEqual(len(asked), 2, asked)
        self.assertGreater(int(asked[1].split()[2]), int(asked[0].split()[2]))

    def test_provider_stopping_returns_to_indentation(self):
        out = self.run_f(self.start() + ['print-present ranges', 'ext-set present stop', 'wait 300',
                                         'print-present ranges', 'key ctrl+Home', 'cmd fold',
                                         'print-present folds'])
        self.assertEqual(self.ranges(out)[0], 'ranges present')
        self.assertIn('ranges indentation', out)
        self.assertEqual(self.folds(out), ['fold 1-7'])

    def test_fold_all_by_provider_then_by_indentation(self):
        out = self.run_f(self.start() + ['cmd fold_all', 'print-present folds', 'cmd unfold_all',
                                         'ext-set present stop', 'wait 300', 'cmd fold_all', 'print-present folds'])
        f = self.folds(out)
        self.assertEqual(f[:3], ['fold 1-8', 'fold 2-5', 'fold 10-12 text=body'])
        self.assertEqual(f[3:], ['fold 1-7', 'fold 2-4', 'fold 10-11'])

    def test_broken_answers_are_dropped(self):
        for body in ('2\n1 8 - 0\n', '1\n1 8 - 5\nab\ncd', '1\n1 8 - 81\n' + 'x' * 81, 'x'):
            self.answer(body)
            out = self.run_f(self.start() + ['print-present ranges'])
            self.assertIn('ranges indentation', out, body)

    def test_no_ranges_means_nothing_folds(self):
        self.answer('1\n4 2 - 0\n')       # START after END: left out; the provider has no ranges
        out = self.run_f(self.start() + ['print-present ranges', 'key ctrl+Home', 'cmd fold', 'cmd fold_all',
                                         'print-present folds'])
        self.assertEqual(self.ranges(out), ['ranges present'])
        self.assertEqual(self.folds(out), [])


if __name__ == '__main__':
    unittest.main()
