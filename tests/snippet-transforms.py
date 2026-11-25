#!/usr/bin/env python3
"""Negotiated compiled transforms through explicit and completion insertion."""
import base64
import shutil
import struct
import unittest
import snippets

FIELDS=((1,0,1,0),(1,2,3,0),(2,4,5,0),(0,5,5,0))
def payload(bindings=((2,b'x'),), flags=0):
    regex=struct.pack('<12I',0x58524e52,1,0x00100000,flags,0,2,0,0,0,0,80,0)+struct.pack('<8I',1,97,0,0,0,0,0,0)
    records=b'';blob=b'';offset=32+24*len(bindings)
    for field,text in bindings:
        replacement=struct.pack('<8I',0x46524e52,1,0x00100000,1,len(text),56+len(text),0,0)+struct.pack('<6I',0,0,0,len(text),0,0)+text
        records+=struct.pack('<6I',field,offset,len(regex),offset+len(regex),len(replacement),0)
        blob+=regex+replacement;offset+=len(regex)+len(replacement)
    return struct.pack('<8I',0x58544e53,1,0x00100000,len(bindings),offset,0,0,0)+records+blob

def wire(raw=None):
    body=base64.b64encode(payload() if raw is None else raw)
    return f'transforms 0 {len(body)}\n'.encode()+body

class Transforms(snippets.Snippets):
    def transform(self,actions,bindings=((2,b'x'),),**kw):
        kw.setdefault('text','a a b');kw.setdefault('fields',FIELDS);kw.setdefault('transforms_feature',True)
        kw.setdefault('extra',snippets.metadata(kw['fields'])+wire(payload(bindings)))
        return self.run_snippet(actions,**kw)
    def reset_extension(self):
        shutil.rmtree(self.work/'snippets',ignore_errors=True)
    def test_leave_mirror_and_undo_redo(self):
        out=self.transform(['print-doc','key Tab','print-doc','print-state','cmd undo','print-doc','cmd redo','print-doc'])
        self.assertEqual([x for x in out if x in ('a a b','a x b')],['a a b','a x b','a a b','a x b'])
        self.assertIn('col=6 sel=1 ',self.states(out)[0])
    def test_primary_and_mirror_are_transformed_as_one_batch(self):
        out=self.transform(['key Tab','print-doc','cmd undo','print-doc','cmd redo','print-doc'],bindings=((1,b'long'),(2,b'x')))
        self.assertEqual([x for x in out if x in ('long x b','a a b')],['long x b','a a b','long x b'])
    def test_live_typing_is_plain_until_leave(self):
        out=self.transform(['type aa','print-doc','key Tab','print-doc'])
        self.assertIn('aa aa b',out);self.assertIn('aa xa b',out)
    def test_provider_can_stop_before_leave(self):
        out=self.transform(['ext-set demo stop','wait 100','key Tab','print-doc'])
        self.assertIn('a x b',out)
    def test_escape_does_not_transform(self):
        out=self.transform(['key Escape','key Tab','print-doc'])
        self.assertNotIn('a x b',out)
    def test_previous_at_first_field_and_revisit(self):
        out=self.transform(['key Shift+Tab','print-doc','print-state','type a','key Tab','print-doc','key Shift+Tab','type a','key Tab','print-doc'])
        self.assertIn('a x b',out);self.assertIn('col=2 sel=1 ',self.states(out)[0])
    def test_before_fields_and_empty_payload(self):
        for raw in (payload(),payload(())):
            self.reset_extension()
            out=self.transform(['key Tab','print-doc'],extra=wire(raw)+snippets.metadata(FIELDS))
            self.assertIn('a x b' if raw==payload() else 'a a b',out)
    def test_completion_and_additional_edit(self):
        (self.proj/'a.txt').write_text('  old')
        extra=snippets.metadata(FIELDS)+wire(payload(((2,b'x\n\ty'),)))
        root=self.extensions(text='a a b',fields=FIELDS,extra=extra,transforms_feature=True,
            complete_range='1 3 1 6',edits=b'edit 1 1 1 1 1\n!')
        out=self.run_editor(['wait 250','cmd complete','wait-complete','key Return','key Tab','print-doc','cmd undo','print-doc'],exts=root)
        self.assertIn('!  a x',out);self.assertIn('    y b',out);self.assertIn('!  a a b',out)
    def test_choices_and_variants(self):
        fields=((1,0,1,0),(1,2,4,0),(2,5,6,0))
        extra=snippets.metadata(fields,((1,('a','aa')),))+b'variant 2 0\n'+wire(payload())
        out=self.transform(['key Down','key Return','print-doc','key Tab','print-doc'],text='a AA b',fields=fields,extra=extra,variants_feature=True)
        self.assertIn('aa aa b',out);self.assertIn('aa xa b',out)
    def test_invalid_explicit_is_atomic_and_completion_is_plain(self):
        valid=wire()
        bad=[valid+valid,valid.replace(b'transforms 0 ',b'transforms 00 ',1),b'transforms 0 4\n====',
             b'transforms 0 0\n',b'transforms 0 4\nZh==',b'transforms 0 4\nZg=\n',wire(b'bad'),
             wire(payload(((0,b'x'),))),wire(payload(((4,b'x'),))),wire(payload(((5,b'x'),))),
             wire(payload(((2,b'x'),(2,b'x')))),valid[:-1],valid+b'garbage']
        for suffix in bad:
            with self.subTest(suffix=suffix[:40]):
                self.reset_extension();extra=snippets.metadata(FIELDS)+suffix
                out=self.transform(['print-doc','print-state'],extra=extra)
                self.assertNotIn('a a b',out);self.assertIn('dirty=0 ',self.states(out)[0])
                self.assertTrue(any(x.startswith('error 20 syntax') for x in self.trace()),self.trace())
                self.reset_extension()
                root=self.extensions(text='a a b',fields=FIELDS,extra=extra,transforms_feature=True)
                out=self.run_editor(['wait 250','cmd complete','wait-complete','key Return','type q','print-doc'],exts=root)
                if suffix in (valid[:-1],valid+b'garbage'): self.assertNotIn('a a bq',out)
                else: self.assertIn('a a bq',out)
    def test_missing_feature_is_atomic_or_plain(self):
        for features,transforms in ((True,False),(False,True)):
            self.reset_extension()
            out=self.transform(['print-state'],features=features,transforms_feature=transforms)
            self.assertIn('dirty=0 ',self.states(out)[0])
            self.reset_extension()
            root=self.extensions(text='a a b',fields=FIELDS,extra=snippets.metadata(FIELDS)+wire(),features=features,transforms_feature=transforms)
            out=self.run_editor(['wait 250','cmd complete','wait-complete','key Return','type q','print-doc'],exts=root)
            self.assertIn('a a bq',out)
    def test_stale_and_readonly(self):
        for kw,code in (({'version_add':1},'stale'),({'needs':'read'},'needs')):
            self.reset_extension();out=self.transform(['print-state'],**kw)
            self.assertIn('dirty=0 ',self.states(out)[0]);self.assertTrue(any(x.startswith('error 20 '+code) for x in self.trace()))

for name in dir(snippets.Snippets):
    if name.startswith('test_') and name not in Transforms.__dict__: setattr(Transforms,name,None)
if __name__=='__main__': unittest.main()
