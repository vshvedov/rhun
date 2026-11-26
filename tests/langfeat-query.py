#!/usr/bin/env python3
"""The language features' query engine (docs/extensions/v1.1.md, "Language feature queries"):
statistics per extension and kind, hard limits and expiry, late and duplicate answers, parts
(query-part) and progress (query-progress), and provider-scope's provides. Providers are
tests/ext/langfake.py driven by a spec.json; other language tests build on the Lang class."""
import json
from pathlib import Path
import unittest

host = __import__('ext-host')
FAKE = Path(__file__).resolve().parent / 'ext' / 'langfake.py'
RS = 'fn main() {\n    let total = 1;\n    total + 1\n}\n'


def loc(path, l1, c1, l2, c2, text=''):
    """One record of a locations body, with {len:...} so paths of any length fit."""
    return f'{l1} {c1} {l2} {c2} {{len:{path}}} {len(text.encode())}\n{path}{text}'


class Lang(host.Host):
    def setUp(self):
        super().setUp()
        (self.proj / 'a.rs').write_text(RS, encoding='utf-8')

    def provider(self, spec, provides, owner='fake', name='lang', root=None, extra=''):
        root = root or self.work / 'lang'
        folder = root / owner / name
        folder.mkdir(parents=True)
        (folder / 'extension.ini').write_text(
            f'name = {name}\nowner = {owner}\ntitle = Lang\nversion = 1\nprotocol = 1\n'
            'runtime = python3\nrun = main.py\non = command\n' + extra +
            '[needs]\ndocuments = write\nproject = read\n[provides]\n' + provides)
        (folder / 'main.py').write_text(FAKE.read_text())
        (folder / 'spec.json').write_text(json.dumps(spec))
        return root

    def lang_log(self, owner='fake', name='lang'):
        p = self.work / f'state/rhun/extensions/{owner}--{name}/lang.log'
        return p.read_text(errors='replace').splitlines() if p.exists() else []

    def run_lang(self, root, actions, files=('a.rs',), owner='fake/lang'):
        return self.run_editor(['wait-ext ' + owner + ' running', 'wait 200', *actions],
                               exts=root, files=files)

    def stats(self, out, kind):
        rows = [l for l in out if f' {kind} asked=' in l]
        return dict(kv.split('=') for kv in rows[-1].split()[2:]) if rows else {}


class Query(Lang):
    def test_answers_are_counted_per_kind(self):
        root = self.provider({'hello': 'hello 1 definition', 'answers': {
            'definition': {'body': '1\n' + loc('{path}', 1, 4, 1, 8, 'main')}}}, 'definition = *.rs\n')
        out = self.run_lang(root, ['cmd definition', 'wait 300', 'print-langstats fake/lang', 'print-state'])
        s = self.stats(out, 'definition')
        self.assertEqual((s['asked'], s['answered'], s['expired'], s['failed']), ('1', '1', '0', '0'), out)
        self.assertTrue(any(' line=1 col=8' in l for l in out if l.startswith('tabs=')), out)

    def test_an_error_is_failed_and_an_empty_answer_empty(self):
        root = self.provider({'hello': 'hello 1 definition references', 'answers': {
            'definition': {'error': 'refused nothing here'}, 'references': {'body': '0\n'}}},
            'definition = *.rs\nreferences = *.rs\n')
        out = self.run_lang(root, ['cmd definition', 'wait 300', 'cmd references', 'wait 300',
                                   'print-langstats fake/lang', 'print-toast'])
        self.assertEqual(self.stats(out, 'definition')['failed'], '1', out)
        self.assertEqual(self.stats(out, 'references')['empty'], '1', out)
        self.assertIn('No references found', out[-1])

    def test_silence_expires_at_the_hard_limit_and_a_late_answer_is_dropped(self):
        root = self.provider({'hello': 'hello 1 definition', 'answers': {
            'definition': {'delay': 6.5, 'body': '1\n' + loc('{path}', 2, 9, 2, 14, 'total')}}}, 'definition = *.rs\n')
        out = self.run_lang(root, ['cmd definition', 'wait 4500', 'print-query', 'wait 1000',
                                   'print-toast', 'print-query', 'wait 1500', 'print-langstats fake/lang',
                                   'print-state'])
        self.assertTrue(any(l.startswith('fake/lang ') and ' definition ' in l for l in out), out)
        self.assertIn('No definition found', '\n'.join(out))
        s = self.stats(out, 'definition')
        self.assertEqual((s['expired'], s['late'], s['answered']), ('1', '1', '0'), out)
        log = self.lang_log()
        rid = next(l.split()[0] for l in log if ' definition ' in l and l[0].isdigit())
        self.assertIn('0 cancel ' + rid, log)
        self.assertTrue(any(' line=1 col=1' in l for l in out if l.startswith('tabs=')), out)

    def test_progress_moves_the_hard_limit(self):
        root = self.provider({'hello': 'hello 1 definition query-stream', 'answers': {
            'definition': {'progress': [[30, 'Indexing', 1.0], ['-', '', 3.5]], 'delay': 2.0,
                           'body': '1\n' + loc('{path}', 2, 9, 2, 14, 'total')}}}, 'definition = *.rs\n')
        out = self.run_lang(root, ['cmd definition', 'wait 1500', 'print-query', 'wait 5500',
                                   'print-langstats fake/lang', 'print-state'])
        self.assertTrue(any('definition pct=30 items=0 text=Indexing' in l for l in out), out)
        s = self.stats(out, 'definition')
        self.assertEqual((s['answered'], s['expired']), ('1', '0'), out)
        self.assertTrue(any(' line=2 col=14' in l for l in out if l.startswith('tabs=')), out)
        self.assertEqual(sum(1 for l in self.lang_log() if l.startswith('ok ')), 2)

    def test_parts_grow_the_answer(self):
        root = self.provider({'hello': 'hello 1 references query-stream', 'answers': {
            'references': {'parts': [['1\n' + loc('{path}', 1, 4, 1, 8, 'fn main() {'), 0.05],
                                     ['1\n' + loc('{path}', 2, 9, 2, 14, 'let total = 1;'), 0.05]],
                           'delay': 0.05, 'body': '1\n' + loc('{path}', 3, 5, 3, 10, 'total + 1')}}},
            'references = *.rs\n')
        out = self.run_lang(root, ['cmd references', 'wait 1500', 'print-results', 'print-langstats fake/lang'])
        rows = [l for l in out if l.startswith('row ') and ' leaf ' in l]    # the Results panel's locations
        self.assertEqual(len(rows), 3, out)
        self.assertEqual(self.stats(out, 'references')['answered'], '1', out)
        log = self.lang_log()
        self.assertEqual(sum(1 for l in log if l.startswith('ok ')), 2, log)

    def test_references_show_at_their_first_part(self):
        root = self.provider({'hello': 'hello 1 references query-stream', 'answers': {
            'references': {'parts': [['1\n' + loc('{path}', 1, 4, 1, 8, 'fn main() {'), 0.05]],
                           'delay': 1.2, 'body': '1\n' + loc('{path}', 3, 5, 3, 10, 'total + 1')}}},
            'references = *.rs\n')
        out = self.run_lang(root, ['cmd references', 'wait 500', 'echo ---', 'print-results', 'wait 1200',
                                   'echo ---', 'print-results', 'print-langstats fake/lang'])
        first, second = '\n'.join(out).split('---')[1:3]
        rows = lambda t: [l for l in t.split('\n') if l.startswith('row ') and ' leaf ' in l]
        self.assertEqual(len(rows(first)), 1, out)
        self.assertEqual(len(rows(second)), 2, out)

    def test_a_list_shown_early_keeps_its_filter_as_parts_come(self):
        root = self.provider({'hello': 'hello 1 implementation navigation query-stream', 'answers': {
            'implementation': {'parts': [['2\n' + loc('{path}', 1, 4, 1, 8, 'main one') + loc('{path}', 2, 9, 2, 14, 'total'),
                                          0.05]],
                               'delay': 1.2, 'body': '1\n' + loc('{path}', 3, 5, 3, 10, 'main two')}}},
            'implementation = *.rs\n')
        out = self.run_lang(root, ['cmd implementation', 'wait 500', 'type main', 'key Down', 'wait 1200',
                                   'print-palette'])
        self.assertIn('field=main', out)
        rows = [l for l in out if l.startswith('  ') or l.startswith('> ')]
        self.assertEqual(len(rows), 2, out)     # "total" stays filtered out
        self.assertTrue(any(l.startswith('> ') and 'main two' in l for l in rows) or
                        any(l.startswith('> ') and 'main one' in l for l in rows), out)

    def test_a_streamed_query_with_records_is_answered_and_signatures_are_not_counts(self):
        root = self.provider({'hello': 'hello 1 references signature query-stream', 'answers': {
            'references': {'parts': [['1\n' + loc('{path}', 1, 4, 1, 8, 'x'), 0.05]], 'delay': 0.05, 'body': '0\n'},
            'signature': {'body': '0 3\nadd(a)\n'}}},
            'references = *.rs\nsignature = *.rs\nsignature.triggers = ( ,\n')
        out = self.run_lang(root, ['cmd references', 'wait 400', 'key Escape', 'cmd signature_help', 'wait 300',
                                   'print-langstats fake/lang'])
        self.assertEqual(self.stats(out, 'references')['answered'], '1', out)
        self.assertEqual(self.stats(out, 'signature')['answered'], '1', out)

    def test_parts_need_the_feature_a_pending_request_and_a_kind_that_streams(self):
        root = self.provider({'hello': 'hello 1 references symbols query-stream', 'answers': {
            'symbols': {'parts': [['0\n', 0.05]], 'delay': 0.2, 'body': '0\n'},
            'references': {'body': '0\n'}},
            'ready': [['query-part 999 2', '0\n'], ['query-progress 999 5 0', '']]},
            'references = *.rs\nsymbols = *.rs\n')
        self.run_lang(root, ['cmd symbols', 'wait 500'])
        log = self.lang_log()
        self.assertIn('error 1 cancelled', log)
        self.assertIn('error 2 cancelled', log)
        self.assertTrue(any(l.startswith('error 3 refused') for l in log), log)
        root2 = self.provider({'hello': 'hello 1 references', 'ready': [['query-part 5 2', '0\n']]},
                              'references = *.rs\n', owner='plain')
        self.run_lang(root2, ['wait 200'], owner='plain/lang')
        self.assertIn('error 1 unknown', self.lang_log(owner='plain'))

    def test_a_malformed_part_is_dropped_and_counted(self):
        root = self.provider({'hello': 'hello 1 references query-stream', 'answers': {
            'references': {'parts': [['2\nbroken', 0.05]], 'delay': 0.2,
                           'body': '1\n' + loc('{path}', 1, 4, 1, 8, 'fn main() {')}}}, 'references = *.rs\n')
        out = self.run_lang(root, ['cmd references', 'wait 1500', 'print-results', 'print-langstats fake/lang'])
        self.assertTrue(any(l.startswith('error 1 syntax') for l in self.lang_log()), self.lang_log())
        s = self.stats(out, 'references')
        self.assertEqual((s['dropped'], s['answered']), ('1', '1'), out)
        rows = [l for l in out if l.startswith('row ') and ' leaf ' in l]
        self.assertEqual(len(rows), 1, out)

    def test_a_second_answer_to_an_id_is_ignored(self):
        root = self.provider({'hello': 'hello 1 definition', 'answers': {
            'definition': {'twice': True, 'body': '1\n' + loc('{path}', 1, 4, 1, 8, 'main')}}}, 'definition = *.rs\n')
        out = self.run_lang(root, ['cmd definition', 'wait 300', 'print-langstats fake/lang'])
        s = self.stats(out, 'definition')
        self.assertEqual((s['answered'], s['late']), ('1', '0'), out)

    def test_a_new_query_withdraws_the_old_one(self):
        root = self.provider({'hello': 'hello 1 definition references', 'answers': {
            'definition': {'silent': True}, 'references': {'body': '0\n'}}},
            'definition = *.rs\nreferences = *.rs\n')
        out = self.run_lang(root, ['cmd definition', 'wait 200', 'cmd references', 'wait 300',
                                   'print-langstats fake/lang', 'print-query'])
        self.assertEqual(self.stats(out, 'definition')['cancelled'], '1', out)
        self.assertEqual(out[-1], 'none')
        self.assertIn('0 cancel 1', self.lang_log())


class Scope(Lang):
    SPEC = {'hello': 'hello 1 definition references provider-scope', 'answers': {
        'definition': {'body': '1\n' + loc('{path}', 1, 4, 1, 8, 'main')}}}

    def test_provides_narrows_withdraws_and_restores(self):
        spec = dict(self.SPEC, run={
            'narrow': [['provides definition *.go', '']],
            'bad': [['provides definition *.py', ''], ['provides bogus *.rs', ''], ['provides references', '']],
            'none': [['provides references -', '']],
            'all': [['provides definition *', ''], ['provides references *', '']]})
        root = self.provider(spec, 'definition = *.rs *.go\nreferences = *.rs\n',
                             extra='[commands]\nnarrow = Narrow\nbad = Bad\nnone = None\nall = All\n')
        out = self.run_lang(root, [
            'cmd lang.narrow', 'wait 200', 'print-provides fake/lang', 'cmd definition', 'wait 200', 'print-toast',
            'cmd lang.bad', 'wait 200', 'cmd lang.none', 'wait 200', 'echo ---', 'print-provides fake/lang',
            'cmd lang.all', 'wait 200', 'echo ---', 'print-provides fake/lang', 'cmd definition', 'wait 300',
            'print-state'])
        text = '\n'.join(out)
        first, second, third = text.split('---')
        self.assertIn('definition = *.go\nreferences = *.rs', first)
        self.assertIn('No extension finds definitions in this file', first)
        self.assertIn('definition = *.go', second)
        self.assertNotIn('references', second)
        self.assertIn('definition = *.rs *.go\nreferences = *.rs', third)
        log = self.lang_log()
        self.assertTrue(any(l.startswith('error 2 refused') for l in log), log)
        self.assertTrue(any(l.startswith('error 3 syntax') for l in log), log)
        self.assertTrue(any(l.startswith('error 4 syntax') for l in log), log)
        self.assertTrue(any(' line=1 col=8' in l for l in out if l.startswith('tabs=')), out)

    def test_editor_providers_follow_the_values_in_force(self):
        spec = dict(self.SPEC, run={'none': [['provides definition -', '']]})
        root = self.provider(spec, 'definition = *.rs\nreferences = *.rs\n', extra='[commands]\nnone = None\n')
        out = self.run_lang(root, ['print-context editorProviders', 'cmd lang.none', 'wait 200',
                                   'print-context editorProviders'])
        ctx = [l for l in out if l.startswith('editorProviders=')]
        self.assertIn('definition', ctx[0])
        self.assertNotIn('definition', ctx[1])
        self.assertIn('references', ctx[1])

    def test_provides_needs_the_feature_and_ends_with_the_process(self):
        spec = {'hello': 'hello 1 definition', 'ready': [['provides definition *.go', '']]}
        root = self.provider(spec, 'definition = *.rs *.go\n')
        out = self.run_lang(root, ['wait 200', 'print-provides fake/lang'])
        self.assertIn('error 1 unknown', self.lang_log())
        self.assertIn('definition = *.rs *.go', out)
        spec = dict(self.SPEC, ready=[['provides definition *.go', '']])
        root = self.provider(spec, 'definition = *.rs *.go\n', owner='other')
        out = self.run_lang(root, ['wait 200', 'print-provides other/lang', 'ext-set other/lang stop',
                                   'wait 300', 'print-provides other/lang'], owner='other/lang')
        defs = [l for l in out if l.startswith('definition = ')]
        self.assertEqual(defs, ['definition = *.go', 'definition = *.rs *.go'], out)


for name in dir(host.Host):
    if name.startswith('test_'):
        setattr(Lang, name, None)

if __name__ == '__main__':
    unittest.main()
