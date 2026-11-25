#!/usr/bin/env python3
"""Interactive extension sessions (feature agent-prompts, wider-parity D4): the prompt box sends
agent-prompt to the open session or starts a new one, Stop sends agent-stop, and agent-ask cards are
answered with the option the user picks, or cancelled. The fake agent is a Python program; nothing
talks to a real agent."""
import json
import unittest

host = __import__('ext-host')

PROGRAM = r'''import os, sys, time
from pathlib import Path
log = Path(os.environ['RHUN_STATE']) / 'agent.log'
out = sys.stdout.buffer
inp = sys.stdin.buffer
next_id = 1
def note(text):
    with log.open('a') as f:
        f.write(text + '\n')
def send(line, body=b''):
    out.write(line.encode() + b'\n' + body)
    out.flush()
def request(text, body=None):
    global next_id
    i = next_id
    next_id += 1
    if body is None:
        send(f'{i} {text}')
    else:
        send(f'{i} {text} {len(body)}', body)
    return i
def row(updated, state, sid, title):
    s, t = sid.encode(), title.encode()
    return f'{updated} {state} {len(s)} {len(t)} 0 0\n'.encode() + s + t
def msg(role, text):
    t = text.encode()
    return f'{role} 0 {len(t)} 0\n'.encode() + t
now = int(time.time())
sessions = {'s1': ['working', 'Fix the bug', [msg('user', 'fix the bug'), msg('assistant', 'On it')]]}
def listing():
    body = f'{len(sessions)}\n'.encode()
    for i, (sid, (state, title, _)) in enumerate(sessions.items()):
        body += row(now - i, state, sid, title)
    request('agent-sessions', body)
asks = []
deferred = []
send(HELLO)
while True:
    line = inp.readline()
    if not line:
        break
    f = line.decode().rstrip('\n').split(' ')
    body = b''
    if len(f) == 4 and f[1] in ('agent-prompt',):
        body = inp.read(int(f[3]))
        note(line.decode().rstrip('\n') + ' ' + body.decode())
    else:
        note(line.decode().rstrip('\n'))
    if f[0] == '0' and f[1] == 'ready':
        listing()
    elif f[1:2] == ['agent-prompt']:
        text = body.decode()
        if text.startswith('refuse'):
            send(f'error {f[0]} refused the agent is busy')
        elif text.startswith('slow'):
            pass                                # never answered: rhun gives up after a while
        elif text.startswith('deferred'):
            deferred.append((f[0], f[2], text))  # answered when the refuse or accept command runs
        elif text.startswith('unlisted'):
            send(f'ok {f[0]} 2', b'zz')         # a session it never lists
        elif f[2] == '-':
            sid = f's{len(sessions) + 1}'
            sessions[sid] = ['working', text, [msg('user', text)]]
            listing()
            send(f'ok {f[0]} {len(sid)}', sid.encode())
        else:
            m = sessions[f[2]][2]
            m += [msg('user', text), msg('assistant', 'ok: ' + text)]
            send(f'ok {f[0]} {len(f[2])}', f[2].encode())
            request(f'agent-changed {f[2]} {len(m)} {len(m) - 2}')
    elif f[0] == '0' and f[1] == 'agent-stop':
        sessions[f[2]][0] = 'idle'
        listing()
    elif f[0] == '0' and f[1] == 'run':
        name = f[2].split('.', 1)[1]
        if name == 'ask':
            last = list(sessions)[-1]           # the newest session
            asks.append(request(f'agent-ask {last}', b'Allow editing src/main.rs?\nAllow once\nAllow always\nDeny'))
        elif name == 'reask':
            asks.append(request('agent-ask s1', b'Run the tests?\nYes\nNo\n'))
        elif name == 'withdraw':
            request(f'cancel {asks[-1]}')
        elif name == 'bad':
            request('agent-ask s1', b'No options\n')
            request('agent-ask s1', b'Empty option\nA\n\nB')
            request('agent-ask nosuch', b'Q\nA')
            request('agent-ask s1', b'Too many\n' + b'\n'.join(b'o%d' % i for i in range(17)))
        elif name == 'refuse':
            send(f'error {deferred.pop()[0]} refused not now')
        elif name == 'accept':
            i, sid, text = deferred.pop()
            sid = f's{len(sessions) + 1}'
            sessions[sid] = ['working', text, [msg('user', text)]]
            listing()
            send(f'ok {i} {len(sid)}', sid.encode())
        elif name == 'bigask':
            opts = b'\n'.join(b'Option %d with a fairly long label so that the card wraps' % i for i in range(1, 17))
            asks.append(request('agent-ask s1', b'Pick one of many\n' + opts))
        elif name == 'drop':
            del sessions['s1']
            listing()
    elif len(f) > 2 and f[1] == 'agent-transcript':
        m = sessions.get(f[2], ['', '', []])[2][int(f[3]):]
        b = f'{len(sessions.get(f[2], ["", "", []])[2])} {len(m)}\n'.encode() + b''.join(m)
        send(f'ok {f[0]} {len(b)}', b)
    elif f[0] == '0' and f[1] == 'bye':
        break
'''


class Prompts(unittest.TestCase):
    setUp = host.Host.setUp
    tearDown = host.Host.tearDown
    run_editor = host.Host.run_editor

    def extension(self, hello='hello 1 agents agent-prompts'):
        root = self.work / 'prompt-exts'
        folder = root / 'acme' / 'gem'
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'extension.ini').write_text(
            'name = gem\nowner = acme\ntitle = Gem Bridge\nversion = 1\nprotocol = 1\n'
            'runtime = python3\nrun = main.py\n[commands]\nask = Ask\nreask = Ask again\nwithdraw = Withdraw\n'
            'bad = Bad\ndrop = Drop\nrefuse = Refuse\naccept = Accept\nbigask = Big ask\n[provides]\nagents = yes\nagents.title = Gemini CLI\n')
        (folder / 'main.py').write_text(f'HELLO = {json.dumps(hello)}\n' + PROGRAM)
        return root

    def agent_log(self):
        p = self.work / 'state/rhun/extensions/acme--gem/agent.log'
        return p.read_text().splitlines() if p.exists() else []

    def logged(self, text):
        return text in '\n'.join(self.agent_log())

    def editor(self, actions, **k):
        return self.run_editor(exts=self.extension(**k), drop_waits=True,
                               actions=['wait-ext acme/gem running', 'wait 300', *actions])

    def inputs(self, out):
        return [l for l in out if l.startswith('input=') or l.startswith('card=')]

    def test_a_prompt_goes_to_the_open_session(self):
        out = self.editor(['print-agents 1', 'wait 300', 'agent-prompt add a test', 'wait 300', 'wait 300',
                           'print-agents', 'print-agent-input'])
        self.assertTrue(self.logged('agent-prompt s1 10 add a test'))
        self.assertEqual(out[-3:-1], ['user add a test', 'agent ok: add a test'])
        self.assertEqual(out[-1], 'input= focus=0 new=- pending=0 box=1')

    def test_typing_in_the_box_and_enter(self):
        # Enter in the panel goes to the box; Shift+Enter is a new line; Enter sends
        out = self.editor(['cmd focus_agents', 'print-agents 1', 'wait 300', 'key Return', 'type first',
                           'key shift+Return', 'type second', 'print-agent-input', 'key Return', 'wait 300',
                           'print-agent-input'])
        self.assertEqual(self.inputs(out), ['input=first', 'input= focus=1 new=- pending=0 box=1'])
        self.assertIn('second focus=1 new=- pending=0 box=1', out)
        self.assertTrue(self.logged('agent-prompt s1 12 first\nsecond'))

    def test_a_new_session_starts_with_its_first_prompt_and_opens(self):
        out = self.editor(['agent-new acme/gem', 'print-agent-input', 'agent-prompt write the docs', 'wait 300',
                           'wait 300', 'print-agents'])
        self.assertIn('input= focus=1 new=acme/gem pending=0 box=1', out)
        self.assertTrue(self.logged('agent-prompt - 14 write the docs'))
        self.assertIn('Gemini CLI: write the docs', out)
        self.assertEqual(out[-1], 'user write the docs')

    def test_a_refused_prompt_comes_back_to_the_box(self):
        out = self.editor(['print-agents 1', 'wait 300', 'agent-prompt refuse this', 'wait 300',
                           'print-agent-input'])
        self.assertEqual(out[-1], 'input=refuse this focus=0 new=- pending=0 box=1')

    def test_stop_sends_agent_stop(self):
        out = self.editor(['print-agents 1', 'wait 300', 'agent-stop', 'wait 300', 'print-agents'])
        self.assertIn('0 agent-stop s1', self.agent_log())
        self.assertIn('Gemini CLI: Fix the bug', out)

    def test_a_card_is_answered_with_the_pick(self):
        out = self.editor(['print-agents 1', 'wait 300', 'cmd acme/gem.ask', 'wait 300', 'print-agent-input',
                           'agent-card 2', 'wait 300', 'print-agent-input'])
        self.assertEqual(self.inputs(out), [
            'input= focus=0 new=- pending=0 box=1',
            'card=Allow editing src/main.rs? options=Allow once|Allow always|Deny',
            'input= focus=0 new=- pending=0 box=1'])
        self.assertIn('ok 2 2', self.agent_log())

    def test_digits_pick_in_the_panel(self):
        self.editor(['cmd focus_agents', 'print-agents 1', 'wait 300', 'cmd acme/gem.ask', 'wait 300',
                     'type 3', 'wait 300', 'type 1', 'wait 300'])
        log = self.agent_log()
        self.assertIn('ok 2 3', log)
        self.assertEqual([l for l in log if l.startswith('ok 2') or l.startswith('error 2')], ['ok 2 3'])

    def test_a_new_card_cancels_the_last_and_withdrawal_closes_it(self):
        out = self.editor(['print-agents 1', 'wait 300', 'cmd acme/gem.ask', 'wait 300', 'cmd acme/gem.reask',
                           'wait 300', 'print-agent-input', 'cmd acme/gem.withdraw', 'wait 300',
                           'print-agent-input'])
        log = self.agent_log()
        self.assertIn('error 2 cancelled', log)
        self.assertIn('card=Run the tests? options=Yes|No', out)
        self.assertIn('error 3 cancelled', log)
        self.assertEqual(self.inputs(out)[-1], 'input= focus=0 new=- pending=0 box=1')

    def test_a_session_that_goes_cancels_its_card(self):
        self.editor(['print-agents 1', 'wait 300', 'cmd acme/gem.ask', 'wait 300', 'cmd acme/gem.drop',
                     'wait 300'])
        self.assertIn('error 2 cancelled', self.agent_log())

    def test_malformed_cards_are_refused(self):
        self.editor(['cmd acme/gem.bad', 'wait 300', 'wait 300'])
        errors = [l for l in self.agent_log() if l.startswith('error ')]
        self.assertEqual(errors, ['error 2 syntax a prompt line and 1 to 16 options, none empty',
                                  'error 3 syntax a prompt line and 1 to 16 options, none empty',
                                  'error 4 refused no such session',
                                  'error 5 toobig more than 16 options'])

    def test_one_prompt_at_a_time_and_a_stopped_extension_ends_it(self):
        out = self.editor(['print-agents 1', 'wait 300', 'agent-prompt slow one', 'wait 300',
                           'agent-prompt second', 'wait 300', 'print-agent-input', 'ext-set acme/gem stop',
                           'wait 1500', 'print-agent-input'])
        self.assertEqual(self.inputs(out), ['input=second focus=0 new=- pending=1 box=1',
                                            'input=second focus=0 new=- pending=0 box=0'])
        self.assertFalse(self.logged('agent-prompt s1 6 second'))

    def test_clicks_on_the_list_button_send_and_card(self):
        # 1000x600 at scale 1: the list header's "+ Gemini CLI", Send, and the card's second option
        out = self.editor(['cmd focus_agents', 'wait 100', 'click 915 60', 'wait 100', 'print-agent-input',
                           'type from a click', 'click 947 548', 'wait 300', 'wait 300', 'print-agents',
                           'cmd acme/gem.ask', 'wait 300', 'click 790 488', 'wait 300'])
        self.assertIn('input= focus=1 new=acme/gem pending=0 box=1', out)
        self.assertTrue(self.logged('agent-prompt - 12 from a click'))
        self.assertIn('ok 3 2', self.agent_log())

    def test_a_click_in_the_box_focuses_it_and_a_click_elsewhere_leaves(self):
        out = self.editor(['cmd focus_agents', 'print-agents 1', 'wait 300', 'click 760 548', 'wait 50',
                           'type typed after a click', 'print-agent-input', 'click 300 300', 'wait 50',
                           'type x', 'print-agent-input'])
        self.assertEqual(self.inputs(out), ['input=typed after a click focus=1 new=- pending=0 box=1',
                                            'input=typed after a click focus=0 new=- pending=0 box=1'])

    def test_an_extension_that_stops_ends_the_session_waiting_to_open(self):
        # the answer named a session it never listed; after a restart its next list must not use
        # the stopped extension's wish (Sonnet review: crash)
        out = self.editor(['agent-new acme/gem', 'agent-prompt unlisted one', 'wait 300',
                           'ext-set acme/gem stop', 'wait 1500', 'ext-set acme/gem restart', 'wait 1500',
                           'wait 300', 'print-extensions', 'print-agent-input'])
        self.assertIn(' state=running ', out[-2])
        self.assertEqual(out[-1], 'input= focus=1 new=- pending=0 box=0')
        self.assertEqual(sum(l.startswith('0 ready ') for l in self.agent_log()), 2)

    def test_a_late_refusal_stays_out_of_another_sessions_box(self):
        out = self.editor(['agent-new acme/gem', 'agent-prompt second one', 'wait 300', 'wait 300',
                           'agent-prompt deferred hi', 'wait 100', 'print-agents 1', 'wait 100',
                           'cmd acme/gem.refuse', 'wait 300', 'print-agent-input'])
        self.assertTrue(self.logged('agent-prompt s2 11 deferred hi'))
        self.assertEqual(out[-1], 'input= focus=1 new=- pending=0 box=1')

    def test_a_refusal_comes_back_when_the_extension_stops(self):
        out = self.editor(['print-agents 1', 'wait 300', 'agent-prompt deferred text', 'wait 100',
                           'ext-set acme/gem stop', 'wait 1500', 'print-agent-input'])
        self.assertEqual(out[-1], 'input=deferred text focus=0 new=- pending=0 box=0')

    def test_hiding_the_panel_gives_the_keys_back(self):
        out = self.editor(['cmd focus_agents', 'print-agents 1', 'wait 300', 'key Return', 'type ab',
                           'cmd toggle_agents', 'wait 50', 'type cd', 'print-agent-input'])
        self.assertEqual(out[-1], 'input=ab focus=0 new=- pending=0 box=1')

    def test_enter_goes_back_to_a_new_sessions_box(self):
        out = self.editor(['agent-new acme/gem', 'key Escape', 'print-agent-input', 'key Return',
                           'print-agent-input'])
        self.assertEqual(self.inputs(out), ['input= focus=0 new=acme/gem pending=0 box=1',
                                            'input= focus=1 new=acme/gem pending=0 box=1'])

    def test_every_option_of_a_cut_card_is_reachable_by_keys(self):
        # Codex review: 16 long options do not fit and 1 to 9 stop at 9; the arrow keys reach them
        out = self.editor(['cmd focus_agents', 'print-agents 1', 'wait 300', 'cmd acme/gem.bigask', 'wait 300',
                           *['key Down'] * 15, 'key Return', 'wait 300', 'print-agent-input'])
        self.assertIn('ok 2 16', self.agent_log())
        self.assertEqual(out[-1], 'input= focus=0 new=- pending=0 box=1')

    def test_text_typed_while_a_new_session_starts_stays_in_its_box(self):
        out = self.editor(['agent-new acme/gem', 'agent-prompt deferred first', 'wait 100', 'type more',
                           'cmd acme/gem.accept', 'wait 300', 'wait 300', 'print-agents', 'print-agent-input'])
        self.assertEqual(out[-2:], ['user deferred first', 'input=more focus=1 new=- pending=0 box=1'])

    def test_a_late_answer_does_not_open_over_a_new_draft(self):
        out = self.editor(['agent-new acme/gem', 'agent-prompt deferred first', 'wait 100', 'key Escape',
                           'key Escape', 'agent-new acme/gem', 'type another', 'cmd acme/gem.accept', 'wait 300',
                           'wait 300', 'print-agent-input'])
        self.assertEqual(out[-1], 'input=another focus=1 new=acme/gem pending=0 box=1')

    def test_keys_in_a_new_draft_leave_the_hidden_card_alone(self):
        # Codex review (round 4): the conversation's card is hidden while a new session is written
        out = self.editor(['cmd focus_agents', 'print-agents 1', 'wait 300', 'cmd acme/gem.ask', 'wait 300',
                           'agent-new acme/gem', 'key Escape', 'key Down', 'key Return', 'type 1', 'wait 300',
                           'print-agent-input'])
        self.assertFalse([l for l in self.agent_log() if l.startswith('ok 2') or l.startswith('error 2')])
        self.assertIn('input=1 focus=1 new=acme/gem pending=0 box=1', out)

    def test_without_the_feature_there_is_no_box(self):
        out = self.editor(['print-agents 1', 'wait 300', 'cmd acme/gem.ask', 'wait 300',
                           'agent-prompt hello', 'wait 300', 'print-agent-input'], hello='hello 1 agents')
        log = self.agent_log()
        self.assertIn('error 2 unknown no such request', log)
        self.assertFalse([l for l in log if 'agent-prompt' in l])
        self.assertIn('input=hello focus=0 new=- pending=0 box=0', out)
        out = self.editor(['agent-new acme/gem', 'print-agent-input'], hello='hello 1 agents')
        self.assertEqual(out[-1], 'input= focus=0 new=- pending=0 box=0')


if __name__ == '__main__':
    unittest.main()
