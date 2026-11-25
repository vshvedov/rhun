#!/usr/bin/env python3
"""Native literal choice dropdowns, independent of the provider after acceptance."""
import unittest
import snippets


class Choices(snippets.Snippets):
    def run_choice(self, actions, **options):
        options.setdefault('choices', ((1, ('one', 'first', '', 'é\n😀')),))
        return self.run_snippet(actions, **options)

    def test_all_choices_show_and_enter_replaces_primary_and_mirrors(self):
        out=self.run_choice(['print-complete','key Down','key Return','print-state','print-doc',
                             'type x','print-doc'])
        self.assertTrue(any('items=4 shown=4 sel=0 labels=one|first|(empty)|é' in s for s in out),out)
        self.assertIn('col=6 sel=0 ',self.states(out)[0])
        self.assertIn('first two first',out)
        self.assertIn('firstx two firstx',out)

    def test_tab_accepts_once_then_advances_and_shift_tab_skips_choice(self):
        out=self.run_choice(['key Down','key Tab','print-state','print-doc','key shift+Tab',
                             'wait 50','print-complete','key Down','key shift+Tab','print-doc','print-state'])
        self.assertIn('col=10 sel=3 ',self.states(out)[0])
        self.assertEqual([s for s in out if s=='first two first'],['first two first']*2)
        self.assertIn('col=6 sel=5 ',self.states(out)[1])

    def test_empty_and_multiline_unicode_options_keep_links(self):
        out=self.run_choice(['key Down','key Down','key Return','print-doc','type z','print-doc',
                             'cmd snippet_choose','wait 50','key Up','key Return','print-doc',
                             'type q','print-doc'])
        self.assertIn(' two ',out)
        self.assertIn('z two z',out)
        joined='\n'.join(out)
        self.assertIn('é\n😀 two é\n😀\n<eod>',joined)
        self.assertIn('é\n😀q two é\n😀q\n<eod>',joined)

    def test_escape_closes_choices_before_finishing_fields(self):
        out=self.run_choice(['key Escape','print-state','type x','print-doc',
                             'cmd snippet_choose','wait 50','key Escape','key Escape','type q','print-doc'])
        self.assertIn('col=4 sel=3 ',self.states(out)[0])
        self.assertIn('x two x',out)
        self.assertIn('xq two x',out)

    def test_freeform_typing_closes_popup_and_can_reopen(self):
        out=self.run_choice(['type custom','print-complete','print-doc','cmd snippet_choose','wait 50',
                             'print-complete','key Down','key Return','print-doc'])
        self.assertIn('custom two custom',out)
        self.assertIn('first two first',out)
        self.assertTrue(any('complete open=0' in s for s in out),out)
        self.assertTrue(any('complete open=2 items=4 shown=4' in s for s in out),out)

    def test_same_value_does_not_add_undo_record(self):
        out=self.run_choice(['key Return','cmd undo','print-doc','cmd redo','print-state','print-doc'])
        # The single undo removes initial insertion, not an identical replacement.
        self.assertEqual([s for s in out if s=='one two one'],['one two one'])
        self.assertIn('col=4 sel=3 ',self.states(out)[0])

    def test_choice_undo_restores_original_partial_selection_and_redo_final(self):
        out=self.run_choice(['key Escape','key Right','key shift+Left','print-state',
                             'cmd snippet_choose','wait 50','key Down','key Tab','print-state','print-doc',
                             'cmd undo','print-state','print-doc','cmd redo','print-state','print-doc'])
        states=self.states(out)
        self.assertIn('col=3 sel=1 ',states[0])
        self.assertIn('col=10 sel=3 ',states[1])
        self.assertIn('col=3 sel=1 ',states[2])
        self.assertIn('col=10 sel=3 ',states[3])
        self.assertEqual([s for s in out if s in ('first two first','one two one')],
                         ['first two first','one two one','first two first'])

    def test_provider_stop_does_not_filter_or_remove_choices(self):
        out=self.run_choice(['key Down','ext-set demo stop','wait 100','print-complete',
                             'key Return','print-doc','cmd snippet_choose','wait 50','print-complete'])
        self.assertTrue(any('items=4 shown=4 sel=1' in s for s in out),out)
        self.assertIn('first two first',out)
        self.assertTrue(any('items=4 shown=4 sel=0' in s for s in out),out)

    def test_ctrl_space_from_selected_primary_requests_provider_at_its_end(self):
        out=self.run_choice(['key ctrl+Space','wait 200','print-complete','key Return','print-doc',
                             'key Tab','print-state'],complete_text='ok',complete_fields=(),
                             complete_range='1 1 1 4',label='one')
        self.assertTrue(any('shown=1' in s for s in out),out)
        self.assertIn('ok two ok',out)
        self.assertIn('col=7 sel=3 ',self.states(out)[0])
        self.assertTrue(any(' complete 1 ' in s and ' 1 4 invoked ' in s for s in self.trace()),self.trace())

    def test_partial_selection_does_not_invoke_provider(self):
        out=self.run_choice(['key Escape','key Right','key shift+Left','key ctrl+Space','wait 100',
                             'print-complete','print-state','type q','print-doc'])
        self.assertTrue(any('complete open=0' in s for s in out),out)
        self.assertFalse(any(len(s.split())>1 and s.split()[1]=='complete' for s in self.trace()),self.trace())
        self.assertIn('col=3 sel=1 ',self.states(out)[0])
        self.assertIn('onq two onq',out)

    def test_all_256_choices_reachable_by_pages_and_mouse(self):
        options=('one',)+tuple(f'option{i:03}' for i in range(1,256))
        out=self.run_choice(['print-complete',*(['key PageDown']*26),'print-complete',
                             'tap 60 338','print-doc'],choices=((1,options),))
        self.assertTrue(any('items=256 shown=256 sel=0' in x for x in out),out)
        self.assertTrue(any('items=256 shown=256 sel=255' in x for x in out),out)
        self.assertIn('option255 two option255',out)

    def test_last_choice_reachable_by_keyboard_wrap(self):
        options=('one',)+tuple(f'option{i:03}' for i in range(1,256))
        out=self.run_choice(['key Up','key Return','print-doc'],choices=((1,options),))
        self.assertIn('option255 two option255',out)

    def test_choice_near_frame_limit_keeps_all_labels_and_options(self):
        options=['one']+[f'{i:03}-'+'x'*16300 for i in range(1,256)]
        fields=((1,0,3,0),(2,4,7,0),(1,8,11,0),(0,11,11,0))
        extra=snippets.metadata(fields,((1,options),))
        size=len(f'0 0 0 0 snippet 0 11 0 {len(extra)}\n'.encode())+11+len(extra)
        options[-1]+='y'*((4<<20)-size)
        extra=snippets.metadata(fields,((1,options),))
        self.assertEqual(len(f'0 0 0 0 snippet 0 11 0 {len(extra)}\n'.encode())+11+len(extra),4<<20)
        out=self.run_choice(['wait 200','print-complete','key Up','key Return','print-state'],choices=((1,options),))
        self.assertTrue(any('items=256 shown=256' in x for x in out),out)
        self.assertIn(f'col={len(options[-1])+1} sel=0 ',self.states(out)[0])

    def test_normal_provider_lists_still_keep_50_best_items(self):
        records=b''.join(f'1 1 1 1 text 4 4 0 0\nv{i:03}v{i:03}'.encode() for i in range(60))
        root=self.extensions(completion=b'60 0\n'+records)
        out=self.run_editor(['wait 300','cmd complete','wait-complete','print-complete'],exts=root)
        self.assertTrue(any('items=60 shown=50' in x for x in out),out)

    def test_nested_choice_updates_all_parent_mirrors_and_redo(self):
        out=self.run_choice(['cmd demo.child','wait 100','key Down','key Return','print-doc',
                             'cmd undo','print-doc','cmd redo','print-state','print-doc'],
                            child_choices=((1,('ab','longer')),))
        self.assertEqual([s for s in out if s in ('longer longer two longer longer','ab ab two ab ab')],
                         ['longer longer two longer longer','ab ab two ab ab','longer longer two longer longer'])
        self.assertIn('col=7 sel=0 ',self.states(out)[0])

    def test_choice_with_mirrors_before_primary_preserves_undo_and_caret(self):
        out=self.run_choice(['key Down','key Return','print-state','print-doc','cmd undo',
                             'print-state','print-doc','cmd redo','print-state','print-doc'],
                            fields=((1,8,11,0),(2,4,7,0),(1,0,3,0),(0,11,11,0)))
        self.assertIn('col=16 sel=0 ',self.states(out)[0])
        self.assertIn('col=12 sel=3 ',self.states(out)[1])
        self.assertIn('col=16 sel=0 ',self.states(out)[2])
        self.assertEqual([s for s in out if s in ('first two first','one two one')],
                         ['first two first','one two one','first two first'])

    def test_inactive_choices_wait_for_the_target_editor(self):
        (self.proj/'b.txt').write_text('foreign')
        root=self.extensions(choices=((1,('one','first')),))
        out=self.run_editor(['cmd demo.inactive','wait 200','print-complete','print-state',
                             'cmd prev_tab','wait 50','print-complete','key Down','key Return','print-doc'],
                            files=('a.txt','b.txt'),exts=root)
        self.assertIn('active=b.txt',self.states(out)[0])
        lists=[x for x in out if x.startswith('complete ')]
        self.assertIn('open=0',lists[0])
        self.assertIn('items=2 shown=2',lists[1])
        self.assertIn('first two first',out)

    def test_palette_focus_is_not_replaced_by_pending_choices(self):
        root=self.extensions(choices=((1,('one','first')),))
        out=self.run_editor(['cmd demo.insert','cmd command_palette','wait 200','print-state','print-complete',
                             'key Escape','wait 100','print-complete'],exts=root)
        lists=[x for x in out if x.startswith('complete ')]
        self.assertIn('open=0',lists[0]);self.assertIn('items=2 shown=2',lists[1])

    def test_external_edit_invalidates_open_choices_before_acceptance(self):
        out=self.run_choice(['cmd demo.plain','wait 100','print-complete','print-doc','key Return','print-doc'])
        self.assertTrue(any('complete open=0' in s for s in out),out)
        self.assertNotIn('first two first',out)
        self.assertIn('!one two one','\n'.join(out))

    def test_invalid_explicit_choices_are_atomic(self):
        out=self.run_choice(['print-doc','print-state'],choices=((1,('mismatch','first')),))
        self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
        self.assertIn('dirty=0 ',self.states(out)[0]);self.assertNotIn('one two one',out)

    def test_invalid_completion_choices_discard_all_new_fields(self):
        root=self.extensions(choices=((1,('mismatch','first')),))
        out=self.run_editor(['wait 200','cmd complete','wait-complete','key Return','print-complete',
                             'type x','print-doc'],exts=root)
        self.assertTrue(any('complete open=0' in s for s in out),out)
        self.assertIn('one two onex',out)

    def test_unnegotiated_completion_ignores_choices(self):
        root=self.extensions(features=False,choices=((1,('one','first')),))
        out=self.run_editor(['wait 200','cmd complete','wait-complete','key Return','print-complete',
                             'type x','print-doc'],exts=root)
        self.assertTrue(any('complete open=0' in s for s in out),out)
        self.assertIn('one two onex',out)

    def test_navigation_back_rebuilds_choices_with_new_selection(self):
        out=self.run_choice(['key Down','cmd snippet_next','cmd snippet_previous','wait 50',
                             'print-complete','key Return','print-doc'])
        self.assertTrue(any('items=4 shown=4 sel=0' in s for s in out),out)
        self.assertIn('one two one',out)

    def test_resuming_outer_after_inner_final_reopens_its_choices(self):
        out=self.run_choice(['cmd demo.child','wait 100','key Tab','wait 50','print-complete',
                             'key Down','key Return','print-doc'])
        self.assertTrue(any('items=4 shown=4 sel=0' in s for s in out),out)
        self.assertIn('first two first',out)

    def test_invalid_new_completion_choices_keep_outer_choices_and_links(self):
        out=self.run_choice(['cmd complete','wait-complete','key Return','print-doc',
                             'cmd snippet_choose','wait 50','key Down','key Return','print-doc'],
                            complete_text='ok',complete_fields=((1,0,2,0),),
                            complete_choices=((1,('invalid','other')),),
                            complete_range='1 1 1 4',label='one')
        self.assertIn('ok two ok',out)
        self.assertIn('first two first',out)

    def test_completion_choice_metadata_opens_native_list_after_acceptance(self):
        root=self.extensions(choices=((1,('one','first')),))
        out=self.run_editor(['wait 200','cmd complete','wait-complete','key Return','wait 50',
                             'print-complete','key Down','key Return','print-doc'],exts=root)
        self.assertTrue(any('items=2 shown=2' in s for s in out),out)
        self.assertIn('first two first',out)

    def test_closed_document_cannot_receive_an_old_choice(self):
        out=self.run_choice(['cmd save','cmd close_tab','open '+str(self.proj/'a.txt'),
                             'print-complete','key Return','print-doc'])
        self.assertTrue(any('complete open=0' in s for s in out),out)
        self.assertNotIn('first two first',out)

# Inherit fixture helpers, without re-running the other snippet or generic host suites.
for _name in dir(snippets.Snippets):
    if _name.startswith('test_'):
        setattr(Choices,_name,None)

if __name__=='__main__':
    unittest.main()
