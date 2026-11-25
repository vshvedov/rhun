#!/usr/bin/env python3
"""Declared initial mirror differences, linked editing, and atomic fallback."""
import unittest
import snippets

FIELDS=((1,0,1,0),(1,2,5,0),(0,5,5,0))
class Variants(snippets.Snippets):
    def variant(self,actions,**kw):
        kw.setdefault('text','a ABC');kw.setdefault('fields',FIELDS)
        kw.setdefault('extra',snippets.metadata(kw['fields'])+b'variant 2 0\n')
        kw.setdefault('variants_feature',True)
        return self.run_snippet(actions,**kw)
    def test_edit_undo_redo_and_navigation(self):
        out=self.variant(['print-state','print-doc','type x','print-doc','key Tab','print-state','cmd undo','print-doc',
                          'cmd redo','print-doc'])
        self.assertIn('col=2 sel=1 ',self.states(out)[0]);self.assertIn('col=4 sel=0 ',self.states(out)[1])
        self.assertEqual([x for x in out if x in ('a ABC','x x')],['a ABC','x x','a ABC','x x'])
    def test_empty_primary_and_backspace(self):
        out=self.variant(['type z','print-doc','key BackSpace','print-doc','type q','print-doc'],
            text=' BIG',fields=((1,0,0,0),(1,1,4,0)))
        self.assertIn('z z',out);self.assertIn(' ',out);self.assertIn('q q',out)
    def test_unicode_multiline_and_provider_stop(self):
        text='é\nq / LONG'
        out=self.variant(['ext-set demo stop','wait 100','type 😀','print-doc'],text=text,
            fields=((1,0,4,0),(1,7,11,0),(0,11,11,0)))
        self.assertIn('😀 / 😀',out)
    def test_mirror_before_primary_and_final_range(self):
        out=self.variant(['type x','print-state','print-doc','key Tab','print-state'],text='ABC a!',
            fields=((1,4,5,0),(1,0,3,0),(0,3,6,0)))
        self.assertIn('x x!',out);self.assertIn('col=5 sel=3 ',self.states(out)[1])
    def test_choice_updates_unequal_mirror(self):
        out=self.variant(['key Down','key Return','print-doc'],extra=snippets.metadata(FIELDS,((1,('a','next')),))+b'variant 2 0\n')
        self.assertIn('next next',out)
    def test_completion_adopts_variants(self):
        root=self.extensions(text='a ABC',fields=FIELDS,extra=snippets.metadata(FIELDS)+b'variant 2 0\n',variants_feature=True)
        out=self.run_editor(['wait 250','cmd complete','wait-complete','key Return','print-doc','type x','print-doc'],exts=root)
        self.assertIn('a ABC',out);self.assertIn('x x',out)
    def test_invalid_explicit_is_atomic(self):
        for suffix in (b'variant 1 0\n',b'variant 3 0\n',b'variant 4 0\n',b'variant 0 0\n',
            b'variant 2 00\n',b'variant 2 1\nx',b'variant 2 0\nvariant 2 0\n',
            b'variant 18446744073709551618 0\n',b'variant -2 0\n'):
            with self.subTest(suffix=suffix):
                # A separate extension folder is needed for each editor run.
                import shutil
                shutil.rmtree(self.work/'snippets',ignore_errors=True)
                out=self.variant(['print-doc','print-state'],extra=snippets.metadata(FIELDS)+suffix)
                self.assertNotIn('a ABC',out);self.assertIn('dirty=0 ',self.states(out)[0])
                self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
    def test_long_leading_zero_index_before_fields(self):
        out=self.variant(['type x','print-doc'],extra=b'variant '+b'0'*1000+b'2 0\n'+snippets.metadata(FIELDS))
        self.assertIn('x x',out)
    def test_unnegotiated_explicit_is_atomic(self):
        out=self.variant(['print-doc','print-state'],variants_feature=False)
        self.assertNotIn('a ABC',out);self.assertIn('dirty=0 ',self.states(out)[0])
    def test_unnegotiated_completion_falls_back(self):
        root=self.extensions(text='a ABC',fields=FIELDS,extra=snippets.metadata(FIELDS)+b'variant 2 0\n')
        out=self.run_editor(['wait 250','cmd complete','wait-complete','key Return','type x','print-doc'],exts=root)
        self.assertIn('a ABCx',out)
    def test_invalid_completion_keeps_outer_links(self):
        data=b'a ABC';extra=snippets.metadata(FIELDS)+b'variant 2 0\n'
        completion=f'1 0\n1 1 1 4 snippet 3 5 0 {len(extra)}\n'.encode()+b'one'+data+extra
        out=self.run_snippet(['cmd complete','wait-complete','key Return','print-doc','type x','print-doc'],completion=completion)
        self.assertIn('a ABC two a ABC',out);self.assertIn('a ABCx two a ABCx',out)
    def test_stale_and_readonly_variants(self):
        out=self.variant(['print-doc'],version_add=1)
        self.assertNotIn('a ABC',out);self.assertTrue(any(x.startswith('error 20 stale') for x in self.trace()))

# Do not inherit the base suite here; it runs separately.
for name in dir(snippets.Snippets):
    if name.startswith('test_') and name not in Variants.__dict__: setattr(Variants,name,None)
if __name__=='__main__': unittest.main()
