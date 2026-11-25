#!/usr/bin/env python3
"""Native editable fields from completions and explicit versioned extension requests."""
import json
import unittest

host = __import__('ext-host')

PEER = r'''
import json, os, sys
from pathlib import Path
trace = open(Path(os.environ['RHUN_STATE'])/'snippet.log', 'w', buffering=1)
versions = {}
def send(header, body=b''):
    sys.stdout.buffer.write(header.encode()+b'\n'+body)
    sys.stdout.buffer.flush()
send(HELLO)
while True:
    line = sys.stdin.buffer.readline()
    if not line: break
    words = line.decode().split()
    body = b''
    if words[:2] == ['0','edits']:
        body = sys.stdin.buffer.read(int(words[4]))
        versions[words[2]] = int(words[3])
    elif words[:2] in (['0','opened'], ['0','resync']):
        versions[words[2]] = int(words[3])
    trace.write(json.dumps({'line':line.decode().strip(), 'body':body.decode(errors='replace')})+'\n')
    if words[:2] == ['0','bye']: break
    if words[:2] == ['0','run']:
        verb = words[2].split('.')[1]
        doc = min(versions,key=int) if verb in ('inactive','leave_return') or (
            verb=='child' and CHILD_INACTIVE) else words[3]
        target = '999999' if verb == 'foreign' else str(int(doc)+DOC_ADD)
        version = versions.get(doc,0) + (1 if verb == 'stale' else 0) + VERSION_ADD
        if verb == 'leave_return':
            send(f'21 select {doc} 1 8 1 8')
            send(f'22 select {doc} 1 2 1 2')
        elif verb == 'plain':
            send(f'21 replace {doc} {version} 1 1 1 1 1', b'!')
        else:
            data, span = (CHILD_RECORD,CHILD_RANGE) if verb=='child' else (
                (GRAND_RECORD,GRAND_RANGE) if verb=='grand' else (RECORD,RANGE))
            args = f'{target} {version} {span}'
            send(f'20 snippet {args}'+(' 0' if verb=='trailing' else '')+f' {len(data)}', data)
    elif len(words)>1 and words[1]=='complete':
        send(f'ok {words[0]} {len(COMPLETION)}', COMPLETION)
'''


def metadata(fields, choices=()):
    extra = ''.join(f'field {g} {a} {b} {p} 0\n' for g,a,b,p in fields).encode()
    for group, options in choices:
        body = b''.join(str(len(o.encode())).encode()+b'\n'+o.encode() for o in options)
        extra += f'choice {group} {len(options)} {len(body)}\n'.encode()+body
    return extra


class Snippets(host.Host):
    def setUp(self):
        super().setUp()
        (self.proj/'a.txt').write_text('')

    def extensions(self, text='one two one', fields=((1,0,3,0),(2,4,7,0),(1,8,11,0),(0,11,11,0)),
                   features=True, needs='write', extra=None, record=None, span='1 1 1 1', edits=b'',
                   complete_range='1 1 1 1', version_add=0, doc_add=0,
                   child_text='ab ab', child_fields=((1,0,2,0),(1,3,5,0),(0,5,5,0)),
                   child_range='1 1 1 4', child_inactive=False,
                   complete_text=None, complete_fields=None, label='label',
                   choices=(), child_choices=(), complete_choices=None, completion=None, variants_feature=False, transforms_feature=False):
        folder = self.work/'snippets/alice/demo'
        folder.mkdir(parents=True)
        (folder/'extension.ini').write_text(
            'name = demo\nowner = alice\ntitle = Snippets\nversion = 1\nprotocol = 1\n'
            'runtime = python3\nrun = main.py\non = command\n[commands]\ninsert = Insert\n'
            'stale = Stale\nforeign = Foreign\nplain = Plain\ntrailing = Trailing\ninactive = Inactive\n'
            'leave_return = Move Selection Out and Back\n'
            'child = Insert Inner\ngrand = Insert Third Level\n'
            f'[needs]\ndocuments = {needs}\nproject = read\n'
            '[subscribe]\nopened = *\nedits = *\n[provides]\ncomplete = *.txt\n')
        data = text.encode()
        if extra is None:
            extra = metadata(fields, choices)
        if record is None:
            record = f'0 0 0 0 snippet 0 {len(data)} 0 {len(extra)}\n'.encode()+data+extra
        def prepared(text,fields,choices=()):
            data=text.encode()
            extra=metadata(fields,choices)
            return f'0 0 0 0 snippet 0 {len(data)} 0 {len(extra)}\n'.encode()+data+extra
        child=prepared(child_text,child_fields,child_choices)
        grand=prepared('z',((1,0,1,0),(0,1,1,0)))
        if complete_text is not None:
            data=complete_text.encode()
        if complete_fields is not None or complete_choices is not None:
            extra=metadata(fields if complete_fields is None else complete_fields,complete_choices or ())
        complete_extra = extra+edits
        completion = (f'1 0\n{complete_range} snippet {len(label.encode())} {len(data)} 0 {len(complete_extra)}\n'.encode()
                      +label.encode()+data+complete_extra) if completion is None else completion
        hello = 'hello 1 complete'+(' snippets' if features else '')+(' snippet-variants' if variants_feature else '')+(' snippet-transforms' if transforms_feature else '')
        (folder/'main.py').write_text(
            f'HELLO={hello!r}\nRECORD={record!r}\nCOMPLETION={completion!r}\nRANGE={span!r}\n'
            f'CHILD_RECORD={child!r}\nCHILD_RANGE={child_range!r}\n'
            f'CHILD_INACTIVE={child_inactive!r}\n'
            f'GRAND_RECORD={grand!r}\nGRAND_RANGE={"1 1 1 3"!r}\n'
            f'VERSION_ADD={version_add!r}\nDOC_ADD={doc_add!r}\n'+PEER)
        return folder.parent.parent

    def run_snippet(self, actions, **options):
        root = self.extensions(**options)
        return self.run_editor(['cmd demo.insert','wait 300',*actions],exts=root)

    def trace(self):
        path = self.work/'state/rhun/extensions/alice--demo/snippet.log'
        return [json.loads(x)['line'] for x in path.read_text().splitlines()]

    def states(self,out):
        return [x for x in out if x.startswith('tabs=')]

    def docs(self,out):
        return '\n'.join(out).split('\n<eod>')[:-1]

    def test_explicit_fields_link_and_navigate_numerically(self):
        out=self.run_snippet(['print-state','type x','print-doc','key Tab','print-state',
                              'type y','key shift+Tab','print-state','key Tab','key Tab','print-state'])
        states=self.states(out)
        self.assertIn('col=4 sel=3 ',states[0])
        self.assertIn('col=6 sel=3 ',states[1])
        self.assertIn('col=2 sel=1 ',states[2])
        self.assertIn('col=6 sel=0 ',states[3])
        self.assertIn('x two x',out)
        self.assertTrue(any(x.startswith('ok 20 ') for x in self.trace()),self.trace())

    def test_completion_attaches_fields_before_tab_navigation(self):
        root=self.extensions()
        out=self.run_editor(['wait 300','cmd complete','wait-complete','print-complete','key Return',
                             'print-state','type x','key Tab','print-state','print-doc'],exts=root)
        self.assertTrue(any('shown=1' in x for x in out),out)
        states=self.states(out)
        self.assertIn('col=4 sel=3 ',states[0])
        self.assertIn('col=6 sel=3 ',states[1])
        self.assertIn('x two x',out)

    def test_completion_invalid_fields_fall_back_as_a_whole(self):
        root=self.extensions(fields=((1,0,3,0),(1,4,7,0),(2,8,11,0)))
        out=self.run_editor(['wait 300','cmd complete','wait-complete','key Return','print-state',
                             'type x','print-doc'],exts=root)
        self.assertIn('col=12 sel=0 ',self.states(out)[0])
        self.assertIn('one two onex',out)

    def test_unnegotiated_completion_ignores_fields(self):
        root=self.extensions(features=False)
        out=self.run_editor(['wait 300','cmd complete','wait-complete','key Return',
                             'print-state','print-doc'],exts=root)
        self.assertIn('col=12 sel=0 ',self.states(out)[0])
        self.assertIn('one two one',out)

    def test_mirrors_before_primary_preserve_typing_undo_redo(self):
        out=self.run_snippet(['key Right','type ab','print-state','print-doc',
                              'cmd undo','print-doc','cmd redo','print-state','print-doc'],
                             text='x x',fields=((1,2,3,0),(1,0,1,0)))
        self.assertEqual([x for x in out if x in ('xab xab','x x')],['xab xab','x x','xab xab'])
        self.assertTrue(all('col=8 sel=0 ' in x for x in self.states(out)),out)

    def test_nested_parent_replacement_retires_external_child_mirror(self):
        out=self.run_snippet(['type z','print-doc','key Tab','type q','print-doc'],
                             text='abc abc b', fields=((1,0,3,0),(2,1,2,1),(1,4,7,0),(2,8,9,0)))
        self.assertIn('z z b',out)
        # The child group has retired, so Tab reaches final and ordinary typing follows it.
        self.assertIn('z z bq',out)

    def test_escape_ends_session_and_collapses_selection(self):
        out=self.run_snippet(['key Escape','print-state','type x','print-doc'])
        self.assertIn('sel=0 ',self.states(out)[0])
        self.assertIn('onex two one',out)

    def test_keyboard_leaving_then_returning_does_not_reactivate_fields(self):
        out=self.run_snippet(['key End','key Home','type x','print-doc'])
        self.assertIn('xone two one',out)

    def test_mouse_leaving_then_returning_does_not_reactivate_fields(self):
        out=self.run_snippet(['tap 112 86','tap 72 86','type q','print-doc'])
        self.assertIn('oqne two one',out)

    def test_motion_inside_active_field_retains_links(self):
        out=self.run_snippet(['key Right','key Left','type x','print-doc'])
        self.assertIn('onxe two onxe',out)

    def test_right_click_selection_leaving_then_returning_cancels_fields(self):
        out=self.run_snippet(['click 112 86 right','key Escape','tap 72 86','type q','print-doc'])
        self.assertIn('oqne two one',out)

    def test_drag_selection_leaving_then_returning_cancels_fields(self):
        out=self.run_snippet(['move 60 86','down','wait 40','move 100 86','wait 40',
                              'up','wait 600','tap 60 86','type q','print-doc'])
        self.assertTrue(any(x.endswith(' two one') and x!='one two one' for x in out),out)

    def test_inactive_external_selection_leaving_then_returning_cancels_fields(self):
        (self.proj/'b.txt').write_text('foreign')
        out=self.run_snippet(['open '+str(self.proj/'b.txt'),'cmd demo.leave_return','wait 200',
                              'cmd prev_tab','type q','print-doc'])
        self.assertTrue(any(x=='ok 21' for x in self.trace()),self.trace())
        self.assertTrue(any(x=='ok 22' for x in self.trace()),self.trace())
        self.assertIn('oqne two one',out)

    def test_stale_request_is_atomic(self):
        root=self.extensions()
        out=self.run_editor(['cmd demo.stale','wait 300','print-doc','print-state'],exts=root)
        self.assertTrue(any(x.startswith('error 20 stale') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])
        self.assertNotIn('one two one',out)

    def test_overflowing_version_cannot_match_a_live_version(self):
        out=self.run_snippet(['print-state'],version_add=1<<64)
        self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_overflowing_doc_cannot_match_a_live_doc(self):
        out=self.run_snippet(['print-state'],doc_add=1<<64)
        self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_overflowing_positions_cannot_wrap_into_the_document(self):
        out=self.run_snippet(['print-state'],span=f'{(1<<64)+1} 1 1 1')
        self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_unknown_doc_is_atomic(self):
        root=self.extensions()
        out=self.run_editor(['cmd demo.foreign','wait 300','print-state'],exts=root)
        self.assertTrue(any(x.startswith('error 20 nodoc') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_explicit_requires_feature_and_write_permission(self):
        for options,code in (({'features':False},'unknown'),({'needs':'read'},'needs')):
            with self.subTest(code=code):
                if (self.work/'snippets').exists():
                    import shutil
                    shutil.rmtree(self.work/'snippets')
                out=self.run_snippet(['print-state'],**options)
                self.assertTrue(any(x.startswith('error 20 '+code) for x in self.trace()),self.trace())
                self.assertIn('dirty=0 ',self.states(out)[0])

    def test_explicit_invalid_metadata_does_not_mutate(self):
        out=self.run_snippet(['print-state'],fields=((1,0,3,0),(1,4,7,0)))
        self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_explicit_rejects_unrecognized_extra_and_trailing_bytes(self):
        out=self.run_snippet(['print-state'],extra=b'cursor 1 0\n')
        self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_explicit_rejects_extra_header_arguments(self):
        root=self.extensions()
        out=self.run_editor(['cmd demo.trailing','wait 300','print-state'],exts=root)
        self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_empty_prepared_completion_keeps_empty_text(self):
        root=self.extensions(text='',fields=((1,0,0,0),(0,0,0,0)))
        out=self.run_editor(['wait 300','cmd complete','wait-complete','key Return','type x',
                             'key Tab','print-state','print-doc'],exts=root)
        self.assertIn('x',out)
        self.assertNotIn('labelx',out)
        self.assertIn('col=2 sel=0 ',self.states(out)[0])

    def test_provider_stop_keeps_accepted_session(self):
        out=self.run_snippet(['ext-set demo stop','wait 100','print-extensions',
                              'type x','print-doc','key Tab','print-state'])
        self.assertTrue(any('state=stopped' in x for x in out),out)
        self.assertIn('x two x',out)
        self.assertIn('col=6 sel=3 ',self.states(out)[0])

    def test_rejected_request_preserves_an_existing_session(self):
        out=self.run_snippet(['cmd demo.stale','wait 200','type x','print-doc','key Tab','print-state'])
        self.assertTrue(any(x.startswith('error 20 stale') for x in self.trace()),self.trace())
        self.assertIn('x two x',out)
        self.assertIn('col=6 sel=3 ',self.states(out)[0])

    def test_external_mutation_cancels_the_session(self):
        out=self.run_snippet(['cmd demo.plain','wait 200','type x','print-doc'])
        self.assertIn('!x two one',out)

    def test_pause_resume_an_inactive_target_does_not_change_focus(self):
        (self.proj/'b.txt').write_text('foreign')
        root=self.extensions()
        out=self.run_editor(['cmd demo.inactive','wait 300','print-state','print-doc',
                             'cmd prev_tab','print-state','type x','print-doc'],
                            files=('a.txt','b.txt'),exts=root)
        self.assertIn('active=b.txt line=1 col=1 sel=0 ',self.states(out)[0])
        self.assertIn('foreign',out)
        self.assertIn('active=a.txt line=1 col=4 sel=3 ',self.states(out)[1])
        self.assertIn('x two x',out)

    def test_numeric_order_is_independent_of_text_order(self):
        out=self.run_snippet(['print-state','key Tab','print-state','key ISO_Left_Tab',
                              'print-state','key Tab','key Tab','print-state'],
                             text='a bb',fields=((2,0,1,0),(1,2,4,0),(0,0,0,0)))
        states=self.states(out)
        self.assertIn('col=5 sel=2 ',states[0])
        self.assertIn('col=2 sel=1 ',states[1])
        self.assertIn('col=5 sel=2 ',states[2])
        self.assertIn('col=1 sel=0 ',states[3])

    def test_unicode_field_offsets_are_bytes(self):
        out=self.run_snippet(['type x','print-doc'],text='é é',fields=((1,0,2,0),(1,3,5,0)))
        self.assertIn('x x',out)

    def test_explicit_rejects_split_unicode_range(self):
        (self.proj/'a.txt').write_text('é', encoding='utf-8')
        out=self.run_snippet(['print-doc','print-state'],span='1 2 1 3')
        self.assertTrue(any(x.startswith('error 20 badpos') for x in self.trace()),self.trace())
        self.assertIn('é',out)
        self.assertIn('dirty=0 ',self.states(out)[0])

    def test_completion_offsets_follow_earlier_additional_edits(self):
        (self.proj/'a.txt').write_text('hi\n')
        root=self.extensions(complete_range='2 1 2 1',edits=b'edit 1 1 1 1 2\n> ')
        out=self.run_editor(['wait 300','key ctrl+End','cmd complete','wait-complete','key Return',
                             'print-state','type x','print-doc'],exts=root)
        self.assertIn('line=2 col=4 sel=3 ',self.states(out)[0])
        self.assertIn('> hi',out)
        self.assertIn('x two x',out)

    def test_autopairs_wrap_the_selected_field_and_mirrors(self):
        out=self.run_snippet(['type (','print-state','print-doc','cmd undo','cmd redo','print-state'],
                             text='x x',fields=((1,0,1,0),(1,2,3,0)))
        self.assertIn('(x) (x)',out)
        self.assertTrue(all('col=3 sel=1 ' in x for x in self.states(out)),out)

    def test_newline_and_backspace_preserve_links(self):
        out=self.run_snippet(['key Right','key Return','print-doc','key BackSpace','print-doc'],
                             text='x x',fields=((1,0,1,0),(1,2,3,0)))
        self.assertIn('x\n x\n\n<eod>', '\n'.join(out))
        self.assertEqual(out[-2:],['x x','<eod>'])

    def test_final_only_and_plain_prepared_insertion(self):
        out=self.run_snippet(['print-state','type q','print-doc'],text='abc',fields=((0,1,1,0),))
        self.assertIn('col=2 sel=0 ',self.states(out)[0])
        self.assertIn('aqbc',out)

    def test_nested_explicit_fields_resume_outer_navigation(self):
        out=self.run_snippet(['cmd demo.child','wait 200','print-state','print-doc','type x',
                              'print-doc','key Tab','print-state','key Tab','print-state',
                              'type y','print-doc'])
        states=self.states(out)
        self.assertIn('col=3 sel=2 ',states[0])
        self.assertIn('col=4 sel=0 ',states[1])
        self.assertIn('col=8 sel=3 ',states[2])
        self.assertIn('ab ab two ab ab',out)
        self.assertIn('x x two x x',out)
        self.assertIn('x x y x x',out)

    def test_nested_insertion_base_moves_with_earlier_outer_mirrors(self):
        out=self.run_snippet(['cmd demo.child','wait 200','print-state','type x','print-doc',
                              'key Tab','key Tab','print-state'],
                             fields=((1,8,11,0),(2,4,7,0),(1,0,3,0),(0,11,11,0)),
                             child_range='1 9 1 12')
        states=self.states(out)
        self.assertIn('col=13 sel=2 ',states[0])
        self.assertIn('col=8 sel=3 ',states[1])
        self.assertIn('x x two x x',out)

    def test_three_levels_propagate_then_resume_each_parent(self):
        out=self.run_snippet(['cmd demo.child','wait 200','cmd demo.grand','wait 200',
                              'type q','print-doc','key Tab','print-state','key Tab',
                              'print-state','key Tab','print-state'])
        self.assertIn('q q two q q',out)
        states=self.states(out)
        self.assertIn('col=2 sel=0 ',states[0])
        self.assertIn('col=4 sel=0 ',states[1])
        self.assertIn('col=8 sel=3 ',states[2])

    def test_nested_acceptance_and_linked_typing_have_separate_undo_steps(self):
        out=self.run_snippet(['cmd demo.child','wait 200','type x','cmd undo','print-doc',
                              'cmd undo','print-doc','cmd redo','print-state','print-doc',
                              'cmd redo','print-state','print-doc'])
        self.assertEqual([x for x in out if x in ('ab ab two ab ab','one two one','x x two x x')],
                         ['ab ab two ab ab','one two one','ab ab two ab ab','x x two x x'])
        self.assertIn('col=3 sel=2 ',self.states(out)[0])
        self.assertIn('col=2 sel=0 ',self.states(out)[1])

    def test_final_only_inner_insertion_does_not_add_a_navigation_level(self):
        out=self.run_snippet(['cmd demo.child','wait 200','print-state','key Tab','print-state'],
                             child_text='abc',child_fields=((0,1,1,0),))
        self.assertIn('col=2 sel=0 ',self.states(out)[0])
        self.assertIn('col=8 sel=3 ',self.states(out)[1])

    def test_plain_completion_preserves_outer_links(self):
        out=self.run_snippet(['key Right','cmd complete','wait-complete','key Return','print-doc',
                              'key Tab','print-state'],complete_text='ok',complete_fields=(),
                             complete_range='1 1 1 4',label='one')
        self.assertIn('ok two ok',out)
        self.assertIn('col=7 sel=3 ',self.states(out)[0])

    def test_nested_completion_pushes_and_resumes_outer_fields(self):
        out=self.run_snippet(['key Right','cmd complete','wait-complete','key Return','print-state',
                              'type x','print-doc','key Tab','key Tab','print-state'],
                             complete_text='ab ab',
                             complete_fields=((1,0,2,0),(1,3,5,0),(0,5,5,0)),
                             complete_range='1 1 1 4',label='one')
        self.assertIn('col=3 sel=2 ',self.states(out)[0])
        self.assertIn('col=8 sel=3 ',self.states(out)[1])
        self.assertIn('x x two x x',out)

    def test_nested_completion_additional_edits_inside_outer_field(self):
        out=self.run_snippet(['key Right','cmd complete','wait-complete','key Return','print-state',
                              'print-doc','type x','print-doc','key Tab','key Tab','print-state'],
                             complete_text='ab',complete_fields=((1,0,2,0),(0,2,2,0)),
                             complete_range='1 2 1 4',label='ne',edits=b'edit 1 1 1 1 2\n> ')
        self.assertIn('col=6 sel=2 ',self.states(out)[0])
        self.assertIn('col=9 sel=3 ',self.states(out)[1])
        self.assertIn('> oab two > oab',out)
        self.assertIn('> ox two > ox',out)

    def test_nested_completion_outside_edits_end_outer_links(self):
        out=self.run_snippet(['key Right','cmd complete','wait-complete','key Return',
                              'type x','print-doc','key Tab','type q','print-doc'],
                             complete_text='ab',complete_fields=((1,0,2,0),(0,2,2,0)),
                             complete_range='1 1 1 4',label='one',edits=b'edit 1 5 1 5 1\n!')
        self.assertIn('x !two one',out)
        self.assertIn('xq !two one',out)

    def test_invalid_new_completion_fields_keep_valid_enclosing_links(self):
        out=self.run_snippet(['key Right','cmd complete','wait-complete','key Return','print-state',
                              'type q','print-doc','key Tab','print-state'],
                             complete_text='ab cd',complete_fields=((1,0,2,0),(1,3,5,0)),
                             complete_range='1 1 1 4',label='one')
        self.assertIn('col=6 sel=0 ',self.states(out)[0])
        self.assertIn('ab cdq two ab cdq',out)
        self.assertIn('col=11 sel=3 ',self.states(out)[1])

    def test_nested_inactive_insertion_keeps_focus_and_outer_links(self):
        (self.proj/'b.txt').write_text('foreign')
        out=self.run_snippet(['open '+str(self.proj/'b.txt'),'cmd demo.child','wait 200',
                              'print-state','cmd prev_tab','print-state','type x','print-doc'],
                             child_inactive=True)
        self.assertIn('active=b.txt line=1 col=1 sel=0 ',self.states(out)[0])
        self.assertIn('active=a.txt line=1 col=3 sel=2 ',self.states(out)[1])
        self.assertIn('x x two x x',out)

    def test_zero_width_inner_field_can_grow_and_resume(self):
        out=self.run_snippet(['cmd demo.child','wait 200','type q','print-doc',
                              'key Tab','key Tab','print-state'],
                             child_text='',child_fields=((1,0,0,0),(0,0,0,0)))
        self.assertIn('q two q',out)
        self.assertIn('col=6 sel=3 ',self.states(out)[0])

    def test_unicode_inner_fields_propagate_through_outer_links(self):
        out=self.run_snippet(['cmd demo.child','wait 200','print-state','type q','print-doc'],
                             child_text='é é',child_fields=((1,0,2,0),(1,3,5,0),(0,5,5,0)))
        self.assertIn('col=2 sel=2 ',self.states(out)[0])
        self.assertIn('q q two q q',out)

    def test_escape_finishes_every_nested_level(self):
        out=self.run_snippet(['cmd demo.child','wait 200','key Escape','type q','print-doc'])
        self.assertIn('abq ab two ab ab',out)

    def test_adjacent_typing_coalesces_with_two_levels_of_mirrors(self):
        out=self.run_snippet(['cmd demo.child','wait 200','key Right','type xy','print-doc',
                              'cmd undo','print-doc','cmd redo','print-state'])
        self.assertIn('abxy abxy two abxy abxy',out)
        self.assertIn('ab ab two ab ab',out)
        self.assertIn('col=5 sel=0 ',self.states(out)[0])

    def test_backspace_keeps_nested_links_when_field_becomes_empty(self):
        out=self.run_snippet(['cmd demo.child','wait 200','key Right','key BackSpace',
                              'key BackSpace','type q','print-doc'])
        self.assertIn('q q two q q',out)


for name in dir(host.Host):
    if name.startswith('test_'):
        setattr(Snippets,name,None)

if __name__=='__main__':
    unittest.main()
