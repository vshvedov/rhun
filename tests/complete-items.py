#!/usr/bin/env python3
"""Completion items of protocol 1.1 (docs/extensions/v1.1.md, feature complete-items): resolve on
selection and the waiting accept, insert and replace ranges, commit characters, filter text,
preselect, adjust, after records, suffix and deprecated; parts of a list (query-part)."""
import unittest

lang = __import__('langfeat-query')
host = lang.host
TEXT = 'fn main() {\n    pr\n}\n'
TAIL = 'fn main() {\n    prXint\n}\n'


def rec(name, body='', args=''):
    b = body.encode()
    head = f'{name} {args} {len(b)}' if args else f'{name} {len(b)}'
    return head + '\n' + body


def item(label, insert, extra='', detail='', kind='function', rng=(2, 5, 2, 7)):
    l1, c1, l2, c2 = rng
    return (f'{l1} {c1} {l2} {c2} {kind} {len(label.encode())} {len(insert.encode())} '
            f'{len(detail.encode())} {len(extra.encode())}\n{label}{insert}{detail}{extra}')


def body(*items, more=0):
    return f'{len(items)} {more}\n' + ''.join(items)


CURSOR = ['key ctrl+Home', 'key Down', 'key End']


class Items(lang.Lang):
    def setUp(self):
        super().setUp()
        (self.proj / 'a.rs').write_text(TEXT, encoding='utf-8')

    def spec(self, items, resolve=None, delay=0, hello='hello 1 complete complete-items', **more):
        answers = {'complete': {'body': items}}
        if resolve is not None:
            answers['complete-resolve'] = {'body': resolve, 'delay': delay}
        answers.update(more)
        return {'hello': hello, 'bodied': ['complete-resolve'], 'answers': answers}

    def run_items(self, spec, actions, provides='complete = *.rs\n', text=None):
        if text:
            (self.proj / 'a.rs').write_text(text, encoding='utf-8')
        root = self.provider(spec, provides)
        actions = [x for a in actions for x in (['echo ===', a] if a == 'print-doc' else [a])]
        return self.run_lang(root, [*CURSOR, *actions])

    def doc(self, out):
        i = len(out) - 1 - out[::-1].index('===')
        j = out.index('<eod>', i)
        return '\n'.join(out[i + 1:j]).rstrip('\n')

    def selected(self, out):
        return [l for l in out if l.startswith('selected label=')]

    def test_the_selected_item_is_resolved(self):
        items = body(item('print', 'print()', rec('resolve', 'r-print', '0')),
                     item('process', 'process', rec('resolve', 'r-process', '0')))
        resolved = rec('doc', 'Prints a line.\nWith a newline.') + rec('detail', 'fn print(s: &str)')
        out = self.run_items(self.spec(items, resolved), ['cmd complete', 'wait 400', 'print-complete',
                                                         'key Down', 'wait 300', 'print-complete'])
        sel = self.selected(out)
        self.assertIn('selected label=print detail=fn print(s: &str) doc=Prints a line.\\nWith a newline. '
                      'resolved=1', sel[0])
        self.assertIn('selected label=process detail=fn print(s: &str)', sel[1])
        log = self.lang_log()
        self.assertTrue(any(' complete-resolve 1 0 7' in l for l in log), log)
        self.assertIn('body r-print', log)
        self.assertIn('body r-process', log)

    def test_accepting_waits_for_a_resolve_that_adds_an_import(self):
        items = body(item('print', 'print()', rec('resolve', 'r', '1')))
        resolved = rec('edit', 'use std::fmt;\n', '1 1 1 1')
        out = self.run_items(self.spec(items, resolved, delay=0.25),
                             ['cmd complete', 'wait 20', 'key Return', 'print-complete', 'wait 600', 'print-doc',
                              'key ctrl+z', 'print-doc'])
        self.assertIn('waiting=1', '\n'.join(out))
        text = '\n'.join(out)
        self.assertIn('use std::fmt;\nfn main() {\n    print()\n}', text)
        self.assertEqual(self.doc(out), TEXT.rstrip('\n'))

    def test_a_late_resolve_accepts_without_its_edits(self):
        items = body(item('print', 'print()', rec('resolve', 'r', '1')))
        resolved = rec('edit', 'use std::fmt;\n', '1 1 1 1')
        out = self.run_items(self.spec(items, resolved, delay=2.0),
                             ['cmd complete', 'wait 20', 'key Return', 'wait 800', 'print-doc'])
        self.assertEqual(self.doc(out), 'fn main() {\n    print()\n}')

    def test_insert_and_replace_ranges(self):
        items = body(item('println', 'println', rec('replace', '', '2 5 2 11')))
        spec = self.spec(items)
        out = self.run_items(spec, ['key Left', 'key Left', 'key Left', 'key Left', 'cmd complete', 'wait 300',
                                    'key Return', 'print-doc', 'cmd complete', 'wait 300'], text=TAIL)
        self.assertIn('    printlnXint', self.doc(out))

    def test_shift_enter_uses_the_replace_range(self):
        items = body(item('println', 'println', rec('replace', '', '2 5 2 11')))
        out = self.run_items(self.spec(items), ['key Left', 'key Left', 'key Left', 'key Left', 'cmd complete',
                                                'wait 300', 'key shift+Return', 'print-doc'], text=TAIL)
        self.assertEqual(self.doc(out), 'fn main() {\n    println\n}')

    def test_complete_replace_setting_swaps_them(self):
        (self.work / 'config/rhun/config').write_text(host.CONFIG + '[editor]\ncomplete_replace = yes\n')
        items = body(item('println', 'println', rec('replace', '', '2 5 2 11')))
        out = self.run_items(self.spec(items), ['key Left', 'key Left', 'key Left', 'key Left', 'cmd complete',
                                                'wait 300', 'key Return', 'print-doc'], text=TAIL)
        self.assertEqual(self.doc(out), 'fn main() {\n    println\n}')

    def test_a_commit_character_accepts_then_types(self):
        items = body(item('println', 'println', rec('commit', '.(')))
        out = self.run_items(self.spec(items), ['cmd complete', 'wait 300', 'print-complete', 'type .',
                                                'print-doc'])
        self.assertIn('commit=.(', '\n'.join(out))
        self.assertEqual(self.doc(out), 'fn main() {\n    println.\n}')

    def test_commit_characters_can_be_turned_off(self):
        (self.work / 'config/rhun/config').write_text(host.CONFIG + '[editor]\ncomplete_commit_characters = no\n')
        items = body(item('println', 'println', rec('commit', '.(')))
        out = self.run_items(self.spec(items), ['cmd complete', 'wait 300', 'type .', 'print-doc'])
        self.assertEqual(self.doc(out), 'fn main() {\n    pr.\n}')

    def test_filter_text_ranks_and_preselect_selects(self):
        items = body(item('print', 'print'), item('Pretty', 'pretty', rec('filter', 'prt')),
                     item('process', 'process', rec('preselect')))
        out = self.run_items(self.spec(items), ['cmd complete', 'wait 300', 'print-complete',
                                                'type t', 'print-complete'])
        lists = [l for l in out if l.startswith('complete open=')]
        self.assertIn('sel=2 labels=print|Pretty|process', lists[0])
        self.assertIn('labels=Pretty|print', lists[1])

    def test_adjust_indents_the_later_lines(self):
        items = body(item('pr_block', 'if x {\n    y\n}', rec('adjust')))
        out = self.run_items(self.spec(items), ['cmd complete', 'wait 300', 'key Return', 'print-doc'])
        self.assertEqual(self.doc(out), 'fn main() {\n    if x {\n        y\n    }\n}')

    def test_after_signature_asks_for_help(self):
        items = body(item('print', 'print()', rec('after', '', 'signature') + rec('cursor', '', '6')))
        spec = self.spec(items, hello='hello 1 complete signature complete-items',
                         signature={'body': '6 11\nprint(s: str)\nPrints.'})
        out = self.run_items(spec, ['cmd complete', 'wait 300', 'key Return', 'wait 300', 'print-complete'],
                             provides='complete = *.rs\nsignature = *.rs\nsignature.triggers = ( ,\n')
        self.assertIn('signature open=1 from=6 to=11 text=print(s: str)', '\n'.join(out))

    def test_suffix_and_deprecated_are_shown(self):
        items = body(item('print', 'print', rec('suffix', '(s: &str)') + rec('deprecated')))
        out = self.run_items(self.spec(items), ['cmd complete', 'wait 300', 'print-complete'])
        self.assertIn('suffix=(s: &str) deprecated=1', '\n'.join(out))

    def test_records_need_the_feature(self):
        items = body(item('print', 'print'), item('process', 'process', rec('preselect')))
        out = self.run_items(self.spec(items, hello='hello 1 complete'), ['cmd complete', 'wait 300', 'print-complete'])
        self.assertTrue(any('sel=0 labels=print|process' in l for l in out), out)

    def test_a_v1_provider_prints_v1s_two_lines(self):
        items = body(item('print', 'print'), item('process', 'process'))
        out = self.run_items(self.spec(items, hello='hello 1 complete'), ['cmd complete', 'wait 300', 'echo ===',
                                                                         'print-complete', 'echo ==='])
        i = out.index('===')
        lines = out[i + 1:out.index('===', i + 1)]
        self.assertEqual(len(lines), 2, lines)
        self.assertTrue(lines[0].startswith('complete open=2 ') and lines[1].startswith('signature '), lines)

    def test_signature_overloads_switch_with_up_and_down(self):
        sigs = [('add(a: i32)', 'One.', (4, 10)), ('add(a: i32, b: i32)', 'Two.', (4, 10)), ('add()', '', (-1, -1))]
        recs = ''.join(f'{f} {t} {len(sig)} {len(doc)}\n{sig}{doc}' for sig, doc, (f, t) in sigs)
        spec = {'hello': 'hello 1 signature signature-list', 'answers': {'signatures': {'body': '3 1\n' + recs}}}
        out = self.run_items(spec, ['cmd signature_help', 'wait 300', 'print-complete', 'key Down', 'print-complete',
                                    'key Down', 'key Down', 'print-complete'],
                             provides='signature = *.rs\nsignature.triggers = ( ,\n')
        sig = [l for l in out if l.startswith('signature open=')]
        self.assertIn('open=1 from=4 to=10 overload=2/3 text=add(a: i32, b: i32)', sig[0])
        self.assertIn('from=- to=- overload=3/3 text=add()', sig[1].replace('from=-1', 'from=-').replace('to=-1', 'to=-'))
        self.assertIn('overload=2/3', sig[2])
        self.assertTrue(any(' signatures 1 ' in l for l in self.lang_log()), self.lang_log())

    def test_an_item_whose_resolve_was_withdrawn_resolves_again(self):
        items = body(item('print', 'print', rec('resolve', 'r-A', '0')), item('process', 'process', rec('resolve', 'r-B', '0')))
        out = self.run_items(self.spec(items, rec('doc', 'Docs'), delay=0.4),
                             ['cmd complete', 'wait 150', 'key Down', 'wait 150', 'key Up', 'wait 800', 'print-complete'])
        self.assertEqual(self.lang_log().count('body r-A'), 2, self.lang_log())
        self.assertIn('selected label=print detail= doc=Docs resolved=1', '\n'.join(out))

    def test_a_commit_character_waits_for_the_imports(self):
        items = body(item('print', 'print', rec('resolve', 'r', '1') + rec('commit', '.')))
        resolved = rec('edit', 'use std::fmt;\n', '1 1 1 1')
        out = self.run_items(self.spec(items, resolved, delay=0.25),
                             ['cmd complete', 'wait 20', 'type .', 'wait 600', 'print-doc'])
        self.assertEqual(self.doc(out), 'use std::fmt;\nfn main() {\n    print.\n}')

    def test_the_resolved_documentation_replaces_the_lists(self):
        items = body(item('print', 'print', rec('doc', 'stub') + rec('resolve', 'r', '0')))
        out = self.run_items(self.spec(items, rec('doc', 'Full documentation')), ['cmd complete', 'wait 400', 'print-complete'])
        self.assertIn('doc=Full documentation resolved=1', '\n'.join(out))

    def test_adjust_applies_to_plain_items_when_snippets_are_agreed(self):
        items = body(item('pr_block', 'if x {\n    y\n}', rec('adjust')))
        out = self.run_items(self.spec(items, hello='hello 1 complete complete-items snippets'),
                             ['cmd complete', 'wait 300', 'key Return', 'print-doc'])
        self.assertEqual(self.doc(out), 'fn main() {\n    if x {\n        y\n    }\n}')

    def test_a_final_answer_cannot_pass_the_query_cap(self):
        many = lambda n, p: body(*[item(f'{p}{i}', 'x', rng=(2, 5, 2, 6)) for i in range(n)])
        spec = {'hello': 'hello 1 complete complete-items query-stream', 'answers': {'complete': {
            'parts': [[many(4096, 'pa'), 0.02], [many(4096, 'pb'), 0.02]], 'delay': 0.05, 'body': many(5, 'pc')}}}
        out = self.run_items(spec, ['cmd complete', 'wait 1500', 'print-complete'], text='fn main() {\n    p\n}\n')
        self.assertTrue(any(' items=8192 ' in l for l in out), [l for l in out if 'items=' in l])

    def test_parts_grow_the_list(self):
        spec = {'hello': 'hello 1 complete complete-items query-stream', 'answers': {'complete': {
            'parts': [[body(item('print', 'print')), 0.05], [body(item('process', 'process')), 0.05]],
            'delay': 0.05, 'body': body(item('private', 'private'))}}}
        out = self.run_items(spec, ['cmd complete', 'wait 1500', 'print-complete', 'print-langstats fake/lang'])
        self.assertTrue(any('items=3 shown=3' in l for l in out), out)
        self.assertEqual(self.stats(out, 'complete')['answered'], '1', out)


if __name__ == '__main__':
    unittest.main()
