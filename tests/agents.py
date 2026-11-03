#!/usr/bin/env python3
"""Agent session discovery handles large metadata, Unicode paths, and Git worktrees."""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
# NTFS keeps file times in steps of 100 ns; elsewhere they are exact to the nanosecond
TICK = 100 if os.name == 'nt' else 1
EXE = Path(os.environ.get('RHUN_TEST_EXE', ROOT / 'build/rhun')).resolve()
META_LIMIT = 1 << 20


def claude_slug(path):
    # Claude's JS regex replaces UTF-16 code units, including both halves of an emoji.
    encoded = path.encode('utf-16-le')
    units = [int.from_bytes(encoded[i:i + 2], 'little') for i in range(0, len(encoded), 2)]
    return ''.join(chr(unit) if (ord('0') <= unit <= ord('9') or
                                 ord('A') <= unit <= ord('Z') or
                                 ord('a') <= unit <= ord('z')) else '-' for unit in units)


class CodexDiscovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-agents-')
        self.home = Path(self.tmp.name).resolve()
        self.project = self.home / 'project café with spaces'
        self.project.mkdir()
        self.session = self.home / '.codex/sessions/2026/10/02/rollout-test.jsonl'
        self.session.parent.mkdir(parents=True)
        self.env = dict(os.environ, HOME=self.home.as_posix(),
                        XDG_CONFIG_HOME=(self.home / 'config').as_posix(),
                        XDG_STATE_HOME=(self.home / 'state').as_posix(), SHELL='/nonexistent')
        for key in ('CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'GROK_HOME'):
            self.env.pop(key, None)
        config = self.home / 'config/rhun/config'
        config.parent.mkdir(parents=True)
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n', encoding='utf-8')

    def tearDown(self):
        self.tmp.cleanup()

    def metadata(self, size=None, cwd=None):
        # Include UTF-8 and escaped newlines; put cwd after the long instructions.
        record = {'type': 'session_meta', 'payload': {
            'base_instructions': 'café\n日本\n',
            'cwd': cwd if cwd is not None else self.project.as_posix()}}
        data = json.dumps(record, ensure_ascii=False).encode('utf-8')
        if size is not None:
            record['payload']['base_instructions'] += 'x' * (size - len(data))
            data = json.dumps(record, ensure_ascii=False).encode('utf-8')
            self.assertEqual(len(data), size)
        return data

    def message(self, role, text):
        record = {'type': 'response_item', 'payload': {
            'type': 'message', 'role': role,
            'content': [{'type': 'input_text' if role == 'user' else 'output_text', 'text': text}]}}
        return json.dumps(record).encode('utf-8') + b'\n'

    def run_editor(self, data, open_thread=False):
        self.session.write_bytes(data)
        script = self.home / 'commands.rsc'
        script.write_text('print-agents' + (' 1' if open_thread else '') + '\nquit\n', encoding='utf-8')
        result = subprocess.run([str(EXE), self.project.as_posix(), '--headless', '1000x700',
                                 '--script', script.as_posix()], env=self.env,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.project), *args], env=self.env,
                                       stderr=subprocess.PIPE)

    def init_repo(self):
        self.git('init', '-q', '-b', 'main')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                 'commit', '--allow-empty', '-qm', 'Initial')

    def add_worktree(self, name):
        path = self.home / name
        path.parent.mkdir(parents=True, exist_ok=True)
        self.git('worktree', 'add', '--detach', str(path))
        return path

    def worktree_sessions(self, worktree, title='Worktree session'):
        codex = self.session.parent / ('rollout-' + claude_slug(str(worktree)) + '.jsonl')
        codex.write_bytes(self.metadata(cwd=str(worktree)) + b'\n' + self.message('user', title))
        claude = self.home / '.claude/projects' / claude_slug(str(worktree)) / 'claude.jsonl'
        claude.parent.mkdir(parents=True, exist_ok=True)
        claude.write_text(json.dumps({'type': 'user', 'cwd': str(worktree), 'message': {
            'role': 'user', 'content': title}}) + '\n', encoding='utf-8')
        os.utime(codex, (2000000000, 2000000000))
        os.utime(claude, (1999999999, 1999999999))

    def fault_library(self):
        library = self.home / 'faults.dylib'
        subprocess.run(['cc', '-dynamiclib', str(ROOT / 'tests/file_faults.c'), '-o', str(library)],
                       check=True)
        return library

    def test_related_worktrees_are_listed_with_names_and_threads(self):
        self.init_repo()
        worktree = self.add_worktree('fix café 日本 🦉')
        self.worktree_sessions(worktree)
        unrelated = self.home / 'unrelated'
        unrelated.mkdir()
        self.worktree_sessions(unrelated, 'Excluded')
        output = self.run_editor(self.metadata() + b'\n', open_thread=True)
        self.assertEqual(output,
                         f'Codex [worktree: {worktree.name}]: Worktree session\n'
                         f'Claude [worktree: {worktree.name}]: Worktree session\n'
                         'Codex: Untitled session\nuser Worktree session\n')

    def test_open_worktree_includes_main_and_sibling_sessions_once(self):
        self.init_repo()
        worktree = self.add_worktree('current-tree')
        sibling = self.add_worktree('sibling-tree')
        self.worktree_sessions(worktree, 'Current')
        self.worktree_sessions(sibling, 'Sibling')
        self.session.write_bytes(self.metadata() + b'\n' + self.message('user', 'Main'))
        os.utime(self.session, (2000000001, 2000000001))
        self.project = worktree
        script = self.home / 'commands.rsc'
        script.write_text('print-agents\nquit\n', encoding='utf-8')
        result = subprocess.run([str(EXE), str(worktree), '--headless', '1000x700',
                                 '--script', str(script)], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.decode('utf-8').splitlines()
        self.assertEqual(len(lines), 5, lines)
        self.assertEqual(lines[0], 'Codex: Main')
        for name, title in ((worktree.name, 'Current'), (sibling.name, 'Sibling')):
            for provider in ('Codex', 'Claude'):
                self.assertIn(f'{provider} [worktree: {name}]: {title}', lines)

    def test_deleted_nested_claude_worktree_is_recovered_without_a_cache(self):
        self.init_repo()
        tree = self.project / '.claude/worktrees/fix café 日本 🦉'
        directory = self.home / '.claude/projects' / claude_slug(str(tree))
        directory.mkdir(parents=True)
        path = directory / 'retired.jsonl'
        path.write_text(json.dumps({'type': 'attachment', 'cwd': str(self.project)}) + '\n' +
                        (json.dumps({'type': 'progress', 'padding': 'x' * 200000}) + '\n') * 4 +
                        json.dumps({'type': 'user', 'cwd': str(tree), 'message': {
                            'role': 'user', 'content': 'Retired history'}}) + '\n' +
                        json.dumps({'type': 'progress', 'padding': 'x' * 1100000}) + '\n')
        unrelated = self.project / '.claude/worktrees-other/wrong'
        self.worktree_sessions(unrelated, 'Excluded')
        for _ in range(2):
            rows = self.worker()[-1][2]
            self.assertEqual([(r['cwd'], r['badge']) for r in rows], [(str(tree), tree.name)])

    def test_known_external_worktrees_survive_deletion_and_index_rebuild(self):
        self.init_repo()
        tree = self.add_worktree('.codex/worktrees/finished/project')
        self.worktree_sessions(tree)
        self.assertEqual(len(self.worker()[-1][2]), 2)
        self.git('worktree', 'remove', str(tree))
        for path in (self.home / 'state/rhun').glob('agents-index-v6-*'):
            path.unlink()
        self.worker(sources='')
        for _ in range(2):
            rows = self.worker()[-1][2]
            self.assertEqual(len(rows), 2)
            self.assertTrue(all(r['cwd'] == str(tree) and r['badge'] == 'finished' for r in rows))

    def test_deleted_worktree_session_leaves_the_page_without_failing_discovery(self):
        # A transcript deleted after it was cached (Claude's cleanup, Codex archiving) has no identity
        # left to check: it drops out, and later runs do not fail on it.
        self.init_repo()
        tree = self.add_worktree('cleaned-tree')
        self.worktree_sessions(tree)
        self.assertEqual(len(self.worker()[-1][2]), 2)
        claude, = self.home.glob('.claude/projects/*/claude.jsonl')
        claude.unlink()
        for _ in range(2):
            self.assertEqual([r['kind'] for r in self.worker()[-1][2]], [2])

    @unittest.skipIf(os.name == 'nt' or os.geteuid() == 0, 'a folder without permissions is readable here')
    def test_unreadable_session_folder_is_skipped_without_failing_discovery(self):
        # A day folder that `sudo codex` left unreadable cannot be read on any run: the rest is listed.
        self.session.write_bytes(self.metadata() + b'\n' + self.message('user', 'Readable'))
        locked = self.home / '.codex/sessions/2026/10/03'
        locked.mkdir(parents=True)
        (locked / 'rollout-locked.jsonl').write_bytes(self.metadata() + b'\n')
        locked.chmod(0)
        try:
            self.assertEqual([r['title'] for r in self.worker()[-1][2]], ['Readable'])
        finally:
            locked.chmod(0o755)

    def test_project_path_too_long_for_a_claude_folder_still_lists_its_sessions(self):
        # The Claude folder of a checkout this deep has a name longer than any file name: Claude cannot
        # have made it, and it is no failure.
        self.project = self.home / ('d' * 100) / ('e' * 100) / ('f' * 60) / 'project'
        self.project.mkdir(parents=True)
        (self.home / '.claude/projects').mkdir(parents=True)   # so the name, not a parent, is missing
        self.session.write_bytes(self.metadata() + b'\n' + self.message('user', 'Deep'))
        self.assertGreater(len(claude_slug(str(self.project))), 255)
        self.assertEqual([r['title'] for r in self.worker()[-1][2]], ['Deep'])

    @unittest.skipIf(os.name == 'nt', 'symbolic links need privileges on Windows')
    def test_project_opened_through_a_symlink_keeps_its_worktree_sessions(self):
        # Git writes a worktree's links as real paths, while the project can be spelled through a
        # symlink (macOS's /tmp is /private/tmp): it is one repository either way.
        self.init_repo()
        tree = self.add_worktree('linked-tree')
        self.worktree_sessions(tree)
        link = self.home / 'project-link'
        link.symlink_to(self.project)
        self.project = link
        for _ in range(2):
            rows = self.worker()[-1][2]
            self.assertEqual(sorted((r['kind'], r['cwd'], r['badge']) for r in rows),
                             [(1, str(tree), tree.name), (2, str(tree), tree.name)])

    def test_replaced_session_identity_cannot_inherit_worktree_membership(self):
        self.init_repo()
        tree = self.add_worktree('reused-session-path')
        self.worktree_sessions(tree)
        self.assertEqual(len(self.worker()[-1][2]), 2)
        self.git('worktree', 'remove', str(tree))
        tree.mkdir()
        subprocess.run(['git', '-C', str(tree), 'init', '-q'], env=self.env, check=True)
        codex, = self.session.parent.glob('rollout-*.jsonl')
        replacement = {'type': 'session_meta', 'payload': {
            'id': 'different-session', 'cwd': str(tree)}}
        codex.write_text(json.dumps(replacement) + '\n')
        rows = self.worker()[-1][2]
        self.assertEqual([r['kind'] for r in rows], [1])

    def test_missing_registered_worktree_is_discovered_on_first_scan(self):
        self.init_repo()
        tree = self.add_worktree('removed-without-pruning')
        self.worktree_sessions(tree)
        shutil.rmtree(tree)
        rows = self.worker()[-1][2]
        self.assertEqual(len(rows), 2)
        self.assertTrue(all(r['badge'] == tree.name for r in rows))

    def test_worktree_history_is_repository_scoped_and_corruption_rebuilds(self):
        self.init_repo()
        tree = self.add_worktree('historical-tree')
        self.worktree_sessions(tree)
        self.worker()
        history, = (self.home / 'state/rhun').glob('agents-worktrees-v2-*/*.root')
        original = history.read_bytes()
        for data in (b'broken', struct.pack('<Q', 2**64 - 1), original[:-1]):
            history.write_bytes(data)
            self.assertEqual(len(self.worker()[-1][2]), 2)
        self.git('worktree', 'remove', str(tree))
        self.project = self.home / 'other-repository'
        self.project.mkdir()
        self.init_repo()
        self.worker()
        other_dir = next(p for p in (self.home / 'state/rhun').glob('agents-worktrees-v2-*')
                         if p != history.parent)
        other = other_dir / history.name
        other.write_bytes(original)
        self.assertEqual(self.worker()[-1][2], [])

    def test_legacy_first_cwd_cache_cannot_hide_the_worktree_badge(self):
        self.init_repo()
        tree = self.project / '.claude/worktrees/legacy-tree'
        directory = self.home / '.claude/projects' / claude_slug(str(tree))
        directory.mkdir(parents=True)
        path = directory / 'legacy.jsonl'
        path.write_text(json.dumps({'type': 'attachment', 'cwd': str(self.project)}) + '\n' +
                        json.dumps({'type': 'user', 'cwd': str(tree), 'message': {
                            'role': 'user', 'content': 'Historical session'}}) + '\n')
        row, = self.worker()[-1][2]
        cache, = (self.home / 'state/rhun').glob('agents-index-v?-*')
        original = cache.read_bytes()
        key_length, = struct.unpack_from('<Q', original)
        strings = [str(path).encode(), str(self.project).encode(), b'Old main identity', b'']
        record = struct.pack('<11Q', 1, 2, row['mtime'], row['stamp'],
                             *(len(s) for s in strings), 0, 0, 0) + b''.join(strings)
        legacy = cache.with_name(cache.name.replace('-v6-', '-v3-'))
        legacy.write_bytes(original[:8 + key_length] +
                           struct.pack('<8sQQQ', b'RAHAIDX3', 1, 1, len(record)) + record)
        if legacy != cache:
            cache.unlink()
        recovered, = self.worker()[-1][2]
        self.assertEqual((recovered['cwd'], recovered['badge']), (str(tree), tree.name))

    def test_legacy_worktree_associations_migrate_without_losing_history(self):
        self.init_repo()
        tree = self.add_worktree('legacy-history')
        self.worktree_sessions(tree)
        self.worker()
        self.git('worktree', 'remove', str(tree))
        history, = (self.home / 'state/rhun').glob('agents-worktrees-v2-*/*.root')
        legacy = history.parent.with_name(history.parent.name.replace('-v2-', '-v1-'))
        legacy.write_bytes(history.read_bytes())
        shutil.rmtree(history.parent)
        self.assertEqual(len(self.worker()[-1][2]), 2)
        self.assertTrue(history.is_file())

    def test_provider_cache_profiles_preserve_legacy_worktree_history(self):
        self.init_repo()
        tree = self.add_worktree('profile-history')
        self.worktree_sessions(tree)
        self.assertEqual(len(self.worker()[-1][2]), 2)
        history, = (self.home / 'state/rhun').glob('agents-worktrees-v2-*/*.root')
        data = history.read_bytes()
        length, = struct.unpack_from('<Q', data)
        self.assertTrue(data[8:8 + length].endswith(b'\n' + self.env['HOME'].encode()),
                        'durable history no longer uses the legacy repository/HOME identity')
        self.git('worktree', 'remove', str(tree))
        self.env['GROK_HOME'] = str(self.home / 'another grok profile')
        for _ in range(2):
            for cache in (self.home / 'state/rhun').glob('agents-index-v6-*'):
                cache.unlink()
            self.assertEqual(len(self.worker()[-1][2]), 2)
        self.assertTrue(history.is_file())
        self.assertEqual(len(list(history.parent.parent.glob('agents-worktrees-v2-*'))), 1)

    def test_reused_worktree_path_keeps_old_history_and_excludes_foreign_sessions(self):
        self.init_repo()
        tree = self.add_worktree('reused-checkout')
        self.worktree_sessions(tree)
        self.assertEqual(len(self.worker()[-1][2]), 2)
        self.git('worktree', 'remove', str(tree))
        tree.mkdir()
        subprocess.run(['git', '-C', str(tree), 'init', '-q'], env=self.env, check=True)
        foreign = self.session.parent / 'foreign.jsonl'
        foreign.write_bytes(self.metadata(cwd=str(tree)) + b'\n' + self.message('user', 'Foreign'))
        foreign_claude = self.home / '.claude/projects' / claude_slug(str(tree)) / 'foreign.jsonl'
        foreign_claude.write_text(json.dumps({'type': 'user', 'cwd': str(tree),
                                             'sessionId': 'foreign-session', 'message': {
                                                 'role': 'user', 'content': 'Foreign'}}) + '\n')
        for _ in range(2):
            rows = self.worker()[-1][2]
            self.assertEqual(len(rows), 2)
            self.assertNotIn(str(foreign), [r['path'] for r in rows])
            self.assertNotIn(str(foreign_claude), [r['path'] for r in rows])
            for cache in (self.home / 'state/rhun').glob('agents-index-v?-*'):
                cache.unlink()
        shutil.rmtree(tree)
        self.assertEqual(len(self.worker()[-1][2]), 2)
        self.git('worktree', 'add', '--detach', str(tree))
        self.worktree_sessions(tree, 'Original repository again')
        for cache in (self.home / 'state/rhun').glob('agents-index-v?-*'):
            cache.unlink()
        self.assertEqual(len(self.worker()[-1][2]), 2)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS read interposition')
    def test_failed_worktree_history_read_preserves_associations(self):
        self.init_repo()
        tree = self.add_worktree('historical-tree')
        self.worktree_sessions(tree)
        self.worker()
        self.git('worktree', 'remove', str(tree))
        history, = (self.home / 'state/rhun').glob('agents-worktrees-v2-*/*.root')
        original = history.read_bytes()
        env = dict(self.env, DYLD_INSERT_LIBRARIES=str(self.fault_library()),
                   RHUN_TEST_FAULT='read', RHUN_TEST_PATH=str(history))
        result = subprocess.run([str(EXE), '--agent-index', str(self.project), '50', 'claude,codex'],
                                env=env, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(history.read_bytes(), original)
        self.assertEqual(len(self.worker()[-1][2]), 2)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS worker delay interposition')
    def test_stale_worker_cannot_erase_new_worktree_associations(self):
        self.init_repo()
        ready = self.home / 'worker-ready'
        env = dict(self.env, DYLD_INSERT_LIBRARIES=str(self.fault_library()),
                   RHUN_TEST_AGENT_DELAY_MS='3000', RHUN_TEST_AGENT_READY=str(ready))
        process = subprocess.Popen([str(EXE), '--agent-index', str(self.project), '50',
                                    'claude,codex'], env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(ready.exists())
            tree = self.add_worktree('concurrent-history')
            self.worktree_sessions(tree)
            self.assertEqual(len(self.worker()[-1][2]), 2)
            self.git('worktree', 'remove', str(tree))
            process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(len(self.worker()[-1][2]), 2)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()

    def test_worktree_path_prefix_does_not_match_another_folder(self):
        self.init_repo()
        worktree = self.add_worktree('tree')
        impostor = self.home / 'tree-other'
        impostor.mkdir()
        self.worktree_sessions(impostor, 'Excluded')
        self.assertEqual(self.run_editor(self.metadata(cwd=str(worktree)) + b'\n'),
                         'Codex [worktree: tree]: Untitled session\n')

    def test_codex_managed_worktrees_use_the_container_name(self):
        self.init_repo()
        worktree = self.add_worktree('.codex/worktrees/website-refresh/project')
        self.worktree_sessions(worktree)
        for opened in (self.project, worktree):
            with self.subTest(opened=str(opened)):
                script = self.home / 'commands.rsc'
                script.write_text('print-agents\nquit\n', encoding='utf-8')
                result = subprocess.run([str(EXE), str(opened), '--headless', '1000x700',
                                         '--script', str(script)], env=self.env,
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.decode('utf-8'),
                                 'Codex [worktree: website-refresh]: Worktree session\n'
                                 'Claude [worktree: website-refresh]: Worktree session\n')

    def test_relative_worktree_registration_and_commondir(self):
        self.init_repo()
        worktree = self.add_worktree('relative-tree')
        self.worktree_sessions(worktree)
        admin = Path((worktree / '.git').read_text(encoding='utf-8').strip().removeprefix('gitdir: '))
        (admin / 'gitdir').write_text(os.path.relpath(worktree / '.git', admin) + '\n', encoding='utf-8')
        main = self.project
        for opened in (main, worktree):
            with self.subTest(opened=str(opened)):
                self.project = opened
                self.assertEqual(self.run_editor(b''),
                                 'Codex [worktree: relative-tree]: Worktree session\n'
                                 'Claude [worktree: relative-tree]: Worktree session\n')

    def test_new_worktree_reconsiders_sessions_and_keeps_the_open_thread(self):
        self.init_repo()
        self.session.write_bytes(self.metadata() + b'\n' + self.message('user', 'Main thread'))
        # This path is initially rejected, then becomes a registered worktree while Rhun runs.
        worktree = self.home / 'new-tree'
        future_session = self.session.parent / 'rollout-future.jsonl'
        future_session.write_bytes(self.metadata(cwd=str(worktree)) + b'\n')
        script = self.home / 'commands.rsc'
        # The first Claude directory is created after startup. Allow the ten-second
        # discovery poll to attach its watch on platforms that cannot watch missing paths.
        script.write_text('print-agents 1\nprint-project\nwait 11000\n'
                          'print-agents\nquit\n', encoding='utf-8')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1000x700',
                                    '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b'Codex: Main thread\n')
            self.assertEqual(process.stdout.readline(), b'user Main thread\n')
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            self.add_worktree(worktree.name)
            self.worktree_sessions(worktree)
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            lines = output.decode('utf-8').splitlines()
            self.assertIn('Codex [worktree: new-tree]: Worktree session', lines)
            self.assertIn('Claude [worktree: new-tree]: Worktree session', lines)
            self.assertIn('Codex [worktree: new-tree]: Untitled session', lines)
            self.assertEqual(lines[-1], 'user Main thread', lines)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_full_discovery_is_paged_past_the_old_codex_budget(self):
        self.init_repo()
        worktree = self.add_worktree('many-sessions')
        data = self.metadata(cwd=str(worktree)) + b'\n'
        for index in range(450):
            (self.session.parent / f'rollout-{index:04}.jsonl').write_bytes(data)
        script = self.home / 'commands.rsc'
        script.write_text('wait-agents\nprint-agents-page\nprint-agents\n' +
                          'agents-more\nwait-agents\n' * 8 +
                          'print-agents-page\nprint-agents\nquit\n', encoding='utf-8')
        result = subprocess.run([str(EXE), str(self.project), '--headless', '1280x800',
                                 '--scale', '1', '--script', str(script)], env=self.env,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode('utf-8').splitlines(),
                         ['shown=50 total=450 loading=0 error=0'] +
                         ['Codex [worktree: many-sessions]: Untitled session'] * 50 +
                         ['shown=450 total=450 loading=0 error=0'] +
                         ['Codex [worktree: many-sessions]: Untitled session'] * 450)

    def test_truncated_worktree_badge_has_the_full_name_in_its_tooltip(self):
        self.init_repo()
        name = 'feature-long-worktree-name-to-check-truncation'
        self.worktree_sessions(self.add_worktree(name))
        config = self.home / 'config/rhun/config'
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n'
                          '[ui]\nagents_panel = true\nagents_width = 240\n')
        script = self.home / 'commands.rsc'
        script.write_text('wait-agents\nmove 1190 118\nwait 650\nprint-tip\nquit\n', encoding='utf-8')
        result = subprocess.run([str(EXE), str(self.project), '--headless', '1280x800',
                                 '--scale', '1', '--script', str(script)], env=self.env,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode('utf-8'), 'tip=' + name + '\n')

    def test_reported_large_record_and_thread(self):
        data = self.metadata(20197) + b'\n'
        data += self.message('user', 'Read the large session')
        data += self.message('assistant', 'The session is visible')
        self.assertEqual(self.run_editor(data, open_thread=True),
                         'Codex: Read the large session\n'
                         'user Read the large session\nagent The session is visible\n')

    def test_result_text_stays_inside_its_box(self):
        # A result's box insets its text, which was measured at the full width of the thread: where the
        # inset made it wrap once more, the last line drew below the box. With the result last, the lowest
        # row drawn in the panel has to be the box's edge, not glyphs.
        output = ('The secret word is pelican.\n\n<subagent_meta>id=01a11c28-9a69-7190-aa70-689d17128c42, '
                  'tool_calls=1, turns=1, duration_ms=3356</subagent_meta>')
        call = {'type': 'response_item', 'payload': {'type': 'function_call', 'name': 'spawn_subagent',
                                                      'arguments': json.dumps({'description': 'Read it'})}}
        result = {'type': 'response_item', 'payload': {'type': 'function_call_output', 'output': output}}
        self.session.write_bytes(self.metadata() + b'\n' + self.message('user', 'Spawn a subagent') +
                                 json.dumps(call).encode() + b'\n' + json.dumps(result).encode() + b'\n')
        for width in (250, 290, 390):   # where the inset takes one more line
            with self.subTest(width=width):
                (self.home / 'config/rhun/config').write_text(
                    '[updates]\ncheck = false\n[git]\nenabled = false\n'
                    f'[ui]\nagents_panel = true\nagents_width = {width}\n', encoding='utf-8')
                shot = self.home / f'result-{width}.ppm'
                self.run_commands(['print-agents 1', f'shot {shot.as_posix()}'])
                magic, dimensions, depth, pixels = shot.read_bytes().split(b'\n', 3)
                self.assertEqual((magic, dimensions, depth), (b'P6', b'1280 800', b'255'))
                def at(x, y):
                    return pixels[(y * 1280 + x) * 3:(y * 1280 + x) * 3 + 3]
                background = at(1274, 720)
                columns = range(1280 - width + 4, 1268)
                drawn = [(y, [at(x, y) for x in columns if at(x, y) != background]) for y in range(100, 740)]
                y, row = [line for line in drawn if line[1]][-1]
                self.assertGreater(row.count(max(set(row), key=row.count)), len(columns) // 2,
                                   f'text drawn below the result box, at y={y}')

    def test_large_session_updates_while_open(self):
        self.session.write_bytes(self.metadata(20197) + b'\n' + self.message('user', 'Live session'))
        script = self.home / 'commands.rsc'
        script.write_text('print-agents 1\nwait 2000\nprint-agents 1\nquit\n', encoding='utf-8')
        process = subprocess.Popen([str(EXE), self.project.as_posix(), '--headless', '1000x700',
                                    '--script', script.as_posix()], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            # Append only after discovery and the initial thread load have finished.
            self.assertEqual(process.stdout.readline(), b'Codex: Live session\n')
            self.assertEqual(process.stdout.readline(), b'user Live session\n')
            with self.session.open('ab') as session:
                session.write(self.message('assistant', 'A live update'))
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'Codex: Live session\nuser Live session\nagent A live update\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS read interposition')
    def test_interrupted_short_and_failed_reads(self):
        library = self.home / 'faults.dylib'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                        str(ROOT / 'tests/file_faults.c'), '-o', str(library)], check=True)
        self.env.update(DYLD_INSERT_LIBRARIES=str(library), RHUN_TEST_PATH=str(self.session))
        # The library fails the first read of the last file it saw opened as the target, or of an
        # atomic write's temporary file: the editor writing one at startup (the last-project file)
        # would take the fault itself, on a later file with the same descriptor. With that file
        # already naming the project, nothing is written, and the fault reaches the worker's read
        # of the session; each case starts without the index cache an earlier one left.
        state = self.home / 'state/rhun'
        state.mkdir(parents=True, exist_ok=True)
        (state / 'last-project').write_text(self.project.as_posix(), encoding='utf-8')
        for fault, errno, expected in (('read', '4', 'Codex: Untitled session\n'),
                                        ('short-read', '5', 'Codex: Untitled session\n'),
                                        ('read', '5', '')):
            with self.subTest(fault=fault, errno=errno):
                for cache in state.glob('agents-index-v6-*'):
                    cache.unlink()
                self.env.update(RHUN_TEST_FAULT=fault, RHUN_TEST_ERRNO=errno)
                self.assertEqual(self.run_editor(self.metadata(20197) + b'\n'), expected)

    def test_read_and_growth_boundaries(self):
        for size in (4095, 4096, 4097, 16383, 16384, 16385, 32768, 65536,
                     262145, META_LIMIT - 1, META_LIMIT):
            with self.subTest(size=size):
                self.assertEqual(self.run_editor(self.metadata(size) + b'\n'), 'Codex: Untitled session\n')

    def test_large_metadata_still_allows_thread_loading(self):
        for size in (262145, META_LIMIT):
            with self.subTest(size=size):
                data = self.metadata(size) + b'\n' + self.message('user', 'After large metadata')
                self.assertEqual(self.run_editor(data, open_thread=True),
                                 'Codex: After large metadata\nuser After large metadata\n')

    def test_claude_large_metadata_does_not_block_discovery_or_loading(self):
        slug = claude_slug(self.project.as_posix())
        session = self.home / '.claude/projects' / slug / 'claude-test.jsonl'
        session.parent.mkdir(parents=True)
        user = json.dumps({'type': 'user', 'message': {
            'role': 'user', 'content': 'After Claude metadata'}}).encode('utf-8') + b'\n'
        for size in (20197, 262145, META_LIMIT, 2 * META_LIMIT):
            with self.subTest(size=size):
                record = {'type': 'user', 'isMeta': True,
                          'message': {'role': 'user', 'content': 'café\n日本\n'}}
                overhead = len(json.dumps(record, ensure_ascii=False).encode('utf-8'))
                record['message']['content'] += 'x' * (size - overhead)
                metadata = json.dumps(record, ensure_ascii=False).encode('utf-8')
                self.assertEqual(len(metadata), size)
                session.write_bytes(metadata + b'\n' + user)
                listed_title = 'After Claude metadata'
                self.assertEqual(self.run_editor(b''), 'Claude: ' + listed_title + '\n')
                self.assertEqual(self.run_editor(b'', open_thread=True),
                                 'Claude: After Claude metadata\nuser After Claude metadata\n')

    def test_claude_unicode_project_paths(self):
        for index, (name, suffix) in enumerate((('café', '-caf-'), ('日本', '---'), ('cafe\u0301', '-cafe-'),
                                                ('emoji 🦉', '-emoji---'), ('é日本🦉Z', '------Z'))):
            with self.subTest(name=name):
                self.project = self.home / f'case{index}' / name
                self.project.mkdir(parents=True)
                slug = claude_slug(self.project.as_posix())
                self.assertTrue(slug.endswith(suffix), slug)
                session = self.home / '.claude/projects' / slug / 'claude-test.jsonl'
                session.parent.mkdir(parents=True)
                record = {'type': 'user', 'message': {'role': 'user', 'content': 'Unicode project'}}
                session.write_bytes(json.dumps(record).encode('utf-8') + b'\n')
                self.assertEqual(self.run_editor(b'', open_thread=True),
                                 'Claude: Unicode project\nuser Unicode project\n')

    def test_eof_without_newline(self):
        for size in (None, 20197, META_LIMIT):
            with self.subTest(size=size):
                self.assertEqual(self.run_editor(self.metadata(size)), 'Codex: Untitled session\n')

    def test_crlf(self):
        data = self.metadata(20197) + b'\r\n' + self.message('user', 'CRLF session')
        self.assertEqual(self.run_editor(data), 'Codex: CRLF session\n')

    def test_other_project_is_excluded(self):
        self.assertEqual(self.run_editor(self.metadata(20197, (self.home / 'other').as_posix()) + b'\n'), '')

    def test_invalid_or_oversized_records_are_excluded(self):
        for data in (b'', b'\n', self.metadata(20197)[:-1] + b'\n',
                     self.metadata(META_LIMIT + 1), self.metadata(META_LIMIT + 1) + b'\n',
                     self.metadata() + b' ' * META_LIMIT + b'\n'):
            with self.subTest(size=len(data)):
                self.assertEqual(self.run_editor(data), '')

    def test_only_first_line_controls_project_matching(self):
        data = self.metadata(cwd=(self.home / 'other').as_posix()) + b'\n'
        data += self.metadata() + b'\n'
        self.assertEqual(self.run_editor(data), '')

    def test_large_later_record_does_not_block_discovery(self):
        data = self.metadata() + b'\n' + b'x' * (META_LIMIT + 1) + b'\n'
        self.assertEqual(self.run_editor(data), 'Codex: Untitled session\n')

    def test_project_switch_reconsiders_codex_sessions(self):
        other = self.home / 'other project 日本'
        other.mkdir()
        projects = (self.project, other)
        listings = {}
        for index, project in enumerate(projects):
            codex = self.session.parent / f'rollout-project-{index}.jsonl'
            codex.write_bytes(self.metadata(20197, project.as_posix()) + b'\n' +
                              self.message('user', 'Codex ' + project.name))
            claude = self.home / '.claude/projects' / claude_slug(project.as_posix()) / 'claude.jsonl'
            claude.parent.mkdir(parents=True)
            claude.write_text(json.dumps({'type': 'user', 'message': {
                'role': 'user', 'content': 'Claude ' + project.name}}) + '\n', encoding='utf-8')
            # Make the provider order deterministic in each project's listing.
            os.utime(codex, (2000000000, 2000000000))
            os.utime(claude, (1999999999, 1999999999))
            listings[project] = ('Codex: Codex ' + project.name + '\n' +
                                 'Claude: Claude ' + project.name + '\n')

        for start, target in (projects, projects[::-1]):
            with self.subTest(start=start.name):
                lines = ['print-agents']
                expected = listings[start]
                for project in (target, start, target, start):
                    lines += [f'open {project.as_posix()}', 'print-agents',
                              'click 1258 60', 'print-agents']
                    expected += listings[project] * 2
                script = self.home / 'commands.rsc'
                script.write_text('\n'.join(lines + ['quit']) + '\n', encoding='utf-8')
                result = subprocess.run([str(EXE), start.as_posix(), '--headless', '1280x800',
                                         '--scale', '1', '--script', script.as_posix()], env=self.env,
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
                self.assertEqual(result.stdout.decode('utf-8'), expected)

    def test_refresh_without_a_project(self):
        # An empty window, or one waiting on a file (--wait), has no project to match codex sessions
        # against. The panel's refresh button still scans; the matcher must not read a null project.
        # A file opened by itself brings in its folder as the project.
        self.session.write_bytes(self.metadata() + b'\n' + self.message('user', 'Codex session'))
        file = self.project / 'standalone.txt'
        file.write_text('standalone\n', encoding='utf-8')
        script = self.home / 'commands.rsc'
        # 1280x800 at scale 1: the refresh button sits in the 40-point panel header, 8 points
        # from the right edge, 28 points square. A window started with a file hides the panel, so
        # focus_agents shows it first.
        script.write_text('print-project\ncmd focus_agents\nprint-panels\nclick 1258 60\nwait 300\n'
                          'print-agents\nquit\n', encoding='utf-8')
        for name, paths, expected in (('project', [self.project.as_posix()], 'Codex: Codex session\n'),
                                      ('file', [file.as_posix()], 'Codex: Codex session\n'),
                                      ('wait', ['--wait', file.as_posix()], ''),
                                      ('empty', ['--empty'], '')):
            with self.subTest(window=name):
                result = subprocess.run([str(EXE), *paths, '--headless', '1280x800', '--scale', '1',
                                         '--script', script.as_posix()], env=self.env,
                                        capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
                output = result.stdout.decode('utf-8')
                project = 'project=~/' + self.project.name + '\n' if name in ('project', 'file') else 'project=\n'
                self.assertEqual(output, project + 'explorer=0 agents=1 term=0\n' * (name in ('file', 'wait')) +
                                 'explorer=1 agents=1 term=0\n' * (name in ('project', 'empty')) + expected)

    def run_commands(self, commands, timeout=20):
        script = self.home / 'commands.rsc'
        script.write_text('\n'.join(commands + ['quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), str(self.project), '--headless', '1280x800',
                                 '--scale', '1', '--script', str(script)], env=self.env,
                                capture_output=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8')

    def make_history(self, count):
        paths = []
        for index in range(count):
            path = self.session.parent / f'rollout-{index:04}.jsonl'
            path.write_bytes(self.metadata() + b'\n' + self.message('user', f'Session {index:04}'))
            os.utime(path, ns=(1700000000000000000 + TICK * index, 1700000000000000000 + TICK * index))
            paths.append(path)
        return paths

    def worker(self, limit=50, sources='claude,codex'):
        result = subprocess.run([str(EXE), '--agent-index', str(self.project), str(limit), sources],
                                env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        packets = []
        offset = 0
        while offset < len(result.stdout):
            magic, count, total, payload = struct.unpack_from('<8sQQQ', result.stdout, offset)
            end = offset + 32 + payload
            packets.append((magic, total, self.decode_records(result.stdout[offset:end])))
            offset = end
        self.assertEqual(offset, len(result.stdout))
        return packets

    @staticmethod
    def decode_records(packet):
        count, = struct.unpack_from('<Q', packet, 8)
        offset = 32
        records = []
        for _ in range(count):
            kind, flags, mtime, stamp, *lengths = struct.unpack_from('<9Q', packet, offset)
            offset += 96
            strings = []
            for length in lengths:
                strings.append(packet[offset:offset + length].decode('utf-8'))
                offset += length
            records.append(dict(kind=kind, flags=flags, mtime=mtime, stamp=stamp,
                                path=strings[0], cwd=strings[1], title=strings[2], badge=strings[3],
                            model=strings[4]))
        assert offset == len(packet)
        return records

    def test_custom_agent_homes_discover_only_the_selected_profile(self):
        self.init_repo()
        self.session.write_bytes(self.metadata() + b'\n' + self.message('user', 'Default Codex'))
        default_claude = self.home / '.claude/projects' / claude_slug(str(self.project)) / 'default.jsonl'
        default_claude.parent.mkdir(parents=True)
        default_claude.write_text(json.dumps({'type': 'user', 'cwd': str(self.project),
                                            'message': {'role': 'user', 'content': 'Default Claude'}}) + '\n')
        self.assertEqual({row['title'] for row in self.worker()[-1][2]},
                         {'Default Claude', 'Default Codex'})
        for profile in ('first café', 'second 日本'):
            claude_home = self.home / profile / 'claude'
            codex_home = self.home / profile / 'codex'
            claude = claude_home / 'projects' / claude_slug(str(self.project)) / 'custom.jsonl'
            codex = codex_home / 'sessions/2026/11/02/custom.jsonl'
            claude.parent.mkdir(parents=True)
            codex.parent.mkdir(parents=True)
            titles = {f'{profile} Claude', f'{profile} Codex'}
            claude.write_text(json.dumps({'type': 'user', 'cwd': str(self.project),
                                         'message': {'role': 'user', 'content': f'{profile} Claude'}}) + '\n')
            codex.write_bytes(self.metadata() + b'\n' + self.message('user', f'{profile} Codex'))
            self.env.update(CLAUDE_CONFIG_DIR=str(claude_home), CODEX_HOME=str(codex_home))
            for _ in range(2):
                packets = self.worker()
                self.assertEqual({row['title'] for row in packets[-1][2]}, titles)
                for _, _, rows in packets:
                    self.assertTrue({row['title'] for row in rows} <= titles, packets)
            output = self.run_commands(['print-agents'])
            for title in titles:
                self.assertIn(title, output)
            self.assertNotIn('Default', output)
        self.env.update(CLAUDE_CONFIG_DIR='', CODEX_HOME='')
        self.assertEqual({row['title'] for row in self.worker()[-1][2]},
                         {'Default Claude', 'Default Codex'})

    def test_grok_profile_switch_does_not_publish_previous_cached_sessions(self):
        self.init_repo()
        for profile in ('first', 'second'):
            home = self.home / profile
            log = home / 'sessions/project/session/updates.jsonl'
            log.parent.mkdir(parents=True)
            log.with_name('summary.json').write_text(json.dumps({
                'info': {'id': profile, 'cwd': str(self.project)}, 'generated_title': profile}))
            log.write_bytes(GrokDiscovery.update(profile, GrokDiscovery.user(profile)))
            self.env['GROK_HOME'] = str(home)
            for _ in range(2):
                packets = self.worker(sources='grok')
                self.assertEqual([row['title'] for row in packets[-1][2]], [profile])
                for _, _, rows in packets:
                    self.assertTrue(all(row['title'] == profile for row in rows), packets)

    def test_load_more_click_and_page_boundaries(self):
        for count in (0, 49, 50, 51, 100, 123):
            with self.subTest(count=count):
                for file in self.session.parent.glob('*.jsonl'):
                    file.unlink()
                self.make_history(count)
                output = self.run_commands(['wait-agents', 'print-agents-page', 'click 1215 752',
                                            'wait-agents', 'print-agents-page', 'agents-more',
                                            'wait-agents', 'print-agents-page'])
                expected_counts = [min(50, count), min(100, count), min(150, count)]
                self.assertEqual(output.splitlines(),
                                 [f'shown={shown} total={count} loading=0 error=0'
                                  for shown in expected_counts])

    def test_nanosecond_recency_and_only_page_titles_are_cached(self):
        paths = self.make_history(123)
        packets = self.worker()
        self.assertEqual([packet[0] for packet in packets], [b'RAHPREV3', b'RAHPAGE3'])
        self.assertEqual(packets[-1][1], 123)
        self.assertEqual([row['title'] for row in packets[-1][2]],
                         [f'Session {index:04}' for index in range(122, 72, -1)])
        cache, = (self.home / 'state/rhun').glob('agents-index-v6-*')
        data = cache.read_bytes()
        key_length, = struct.unpack_from('<Q', data)
        rows = self.decode_records(data[8 + key_length:])
        self.assertEqual(len(rows), 123)
        self.assertEqual(sum(bool(row['flags'] & 2) for row in rows), 50)
        self.assertEqual(sum(bool(row['title']) for row in rows), 50)
        warm = self.worker(100)
        self.assertEqual(len(warm[0][2]), 100)
        self.assertEqual(len(warm[-1][2]), 100)
        self.assertEqual(warm[-1][2][-1]['title'], 'Session 0023')
        # An older session resumed on disk belongs at the top, despite its filename/date.
        with paths[0].open('ab') as stream:
            stream.write(self.message('assistant', 'Resumed'))
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Session 0000')

    def test_worker_finishes_with_a_project_path_spelled_another_way(self):
        # Another program can start the worker with a relative path, or a C:\ path on Windows: the
        # search for the repository above it once tried the path's first letter forever.
        self.make_history(2)
        for project in (self.project.name, str(self.project)):
            with self.subTest(project=project):
                result = subprocess.run([str(EXE), '--agent-index', project, '50', 'claude,codex'],
                                        cwd=self.home, env=self.env, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout.startswith(b'RAHPREV3'))

    def test_mixed_sources_and_worktrees_share_one_recent_page(self):
        self.init_repo()
        tree = self.add_worktree('history-tree')
        paths = self.make_history(30)
        directory = self.home / '.claude/projects' / claude_slug(str(tree))
        directory.mkdir(parents=True)
        for index in range(30):
            path = directory / f'claude-{index:04}.jsonl'
            path.write_text(json.dumps({'type': 'user', 'message': {
                'role': 'user', 'content': f'Claude {index:04}'}}) + '\n')
            os.utime(path, ns=(1700000000000000000 + TICK * 2 * index,
                              1700000000000000000 + TICK * 2 * index))
            os.utime(paths[index], ns=(1700000000000000000 + TICK * (2 * index + 1),
                                      1700000000000000000 + TICK * (2 * index + 1)))
        rows = self.worker()[-1][2]
        self.assertEqual(len(rows), 50)
        self.assertEqual([row['kind'] for row in rows], [2, 1] * 25)
        self.assertEqual([row['badge'] for row in rows], ['', 'history-tree'] * 25)
        self.assertEqual(len(self.worker(sources='codex')[-1][2]), 30)
        self.assertEqual(len(self.worker(sources='claude')[-1][2]), 30)

    def test_corrupt_cache_rebuilds_and_unwritable_state_still_lists(self):
        self.make_history(3)
        self.worker()
        cache, = (self.home / 'state/rhun').glob('agents-index-v6-*')
        for data in (b'broken', struct.pack('<Q', 2**64 - 1), cache.read_bytes()[:-1]):
            with self.subTest(size=len(data)):
                cache.write_bytes(data)
                self.assertEqual(len(self.worker()[-1][2]), 3)
        unavailable = self.home / 'not-a-directory'
        unavailable.write_text('file')
        self.env['XDG_STATE_HOME'] = str(unavailable)
        self.assertEqual(len(self.worker()[-1][2]), 3)
        self.env['XDG_STATE_HOME'] = str(self.home / 'state')
        state = self.home / 'state/rhun'
        state.chmod(0)
        try:
            self.assertEqual(len(self.worker()[-1][2]), 3)
        finally:
            state.chmod(0o700)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS read interposition')
    def test_unchanged_cache_does_not_reread_session_files(self):
        self.make_history(2)
        self.worker()
        target = self.session.parent / 'rollout-0001.jsonl'
        library = self.home / 'faults.dylib'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                        str(ROOT / 'tests/file_faults.c'), '-o', str(library)], check=True)
        self.env.update(DYLD_INSERT_LIBRARIES=str(library), RHUN_TEST_PATH=str(target),
                        RHUN_TEST_FAULT='read', RHUN_TEST_ERRNO='5')
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Session 0001')
        target.write_bytes(self.metadata(cwd=str(self.home / 'other')) + b'\n')
        self.assertEqual(len(self.worker()[-1][2]), 2)  # a failed read keeps cached metadata
        del self.env['DYLD_INSERT_LIBRARIES']
        self.assertEqual(len(self.worker()[-1][2]), 1)

    def test_refresh_keeps_an_open_conversation_outside_the_new_page(self):
        paths = self.make_history(50)
        script = self.home / 'commands.rsc'
        script.write_text('print-agents 50\nprint-project\nwait 2000\n'
                          'wait-agents\nprint-agents-page\nprint-agents\nquit\n')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            for _ in range(50):
                self.assertTrue(process.stdout.readline().startswith(b'Codex: Session '))
            self.assertEqual(process.stdout.readline(), b'user Session 0000\n')
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            new = self.session.parent / 'rollout-new.jsonl'
            new.write_bytes(self.metadata() + b'\n' + self.message('user', 'Newest session'))
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            lines = output.decode('utf-8').splitlines()
            self.assertEqual(lines[0], 'shown=50 total=51 loading=0 error=0')
            self.assertEqual(lines[1], 'Codex: Newest session')
            self.assertNotIn('Codex: Session 0000', lines)
            self.assertEqual(lines[-1], 'user Session 0000')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()

    def test_deleted_sessions_leave_the_final_page(self):
        paths = self.make_history(55)
        self.worker()
        for path in paths[-10:]:
            path.unlink()
        packets = self.worker()
        self.assertEqual(packets[0][1], 55)   # cached page is provisional
        self.assertEqual(packets[-1][1], 45)
        self.assertEqual(len(packets[-1][2]), 45)

    def test_project_switch_cancels_in_flight_discovery(self):
        self.make_history(1000)
        other = self.home / 'other'
        other.mkdir()
        path = self.session.parent / 'other.jsonl'
        path.write_bytes(self.metadata(cwd=str(other)) + b'\n' + self.message('user', 'Other'))
        output = self.run_commands([f'open {other}', 'wait-agents', 'print-agents-page',
                                    'print-agents'])
        self.assertEqual(output, 'shown=1 total=1 loading=0 error=0\nCodex: Other\n')

    def test_hidden_panel_defers_discovery_until_shown(self):
        self.make_history(55)
        config = self.home / 'config/rhun/config'
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n'
                          '[ui]\nagents_panel = false\n')
        output = self.run_commands(['wait 1100', 'print-agents-page', 'cmd toggle_agents',
                                    'wait-agents', 'print-agents-page'])
        self.assertEqual(output, 'shown=0 total=0 loading=1 error=0\n'
                                 'shown=50 total=55 loading=0 error=0\n')

    def test_cache_rejects_invalid_lengths_flags_and_duplicate_paths(self):
        self.make_history(2)
        self.worker()
        cache, = (self.home / 'state/rhun').glob('agents-index-v6-*')
        original = cache.read_bytes()
        key_length, = struct.unpack_from('<Q', original)
        start = 8 + key_length
        record = start + 32
        cases = []
        for offset, value in ((start + 8, 100001), (start + 16, 0),
                              (record, 99), (record + 8, 8),
                              (record + 32, 2**64 - 1), (record + 48, 121)):
            damaged = bytearray(original)
            struct.pack_into('<Q', damaged, offset, value)
            cases.append(damaged)
        cases.append(original + b'junk')
        rows = self.decode_records(original[start:])
        self.assertEqual(len(rows), 2)
        # Same length paths, duplicate record identity, otherwise structurally valid.
        cases.append(original.replace(rows[1]['path'].encode(), rows[0]['path'].encode()))
        for index, damaged in enumerate(cases):
            with self.subTest(case=index):
                cache.write_bytes(damaged)
                self.assertEqual(len(self.worker()[-1][2]), 2)

    @unittest.skipIf(os.name == 'nt', 'Windows cannot rename a folder while rhun watches one inside it')
    def test_worker_failure_reports_error_and_keeps_previous_rows(self):
        self.make_history(3)
        script = self.home / 'commands.rsc'
        script.write_text('print-agents\nprint-project\nwait 1500\n'
                          'click 1258 60\nwait-agents\nprint-agents-page\nprint-agents\nquit\n')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            before = [process.stdout.readline() for _ in range(3)]
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            directory = self.home / '.codex/sessions'
            directory.rename(directory.with_name('saved-sessions'))
            directory.write_text('not a directory')
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'shown=3 total=3 loading=0 error=1\n' + b''.join(before))
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()

    def test_sources_changed_in_settings_are_passed_before_save(self):
        import re
        self.make_history(1)
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        (directory / 'c.jsonl').write_text(json.dumps({'type': 'user', 'message': {
            'role': 'user', 'content': 'Claude only'}}) + '\n')
        rows = []
        for line in (ROOT / 'src/app/config.s').read_text().splitlines():
            match = re.match(r'\s+SETTING(?:_ACTION)? \.Ls_(\w+), (\w+), (\w+)', line)
            if match:
                rows.append(match.groups())
        y, previous = 268, None
        for section, key, _ in rows:
            if (section, key) == ('ui', 'theme'):
                continue                # shown only without Follow system dark mode
            if section != previous:
                y += 48
                previous = section
            if (section, key) == ('agents', 'codex'):
                y += 32
                break
            y += 72
        script = self.home / 'commands.rsc'
        # Codex's switch, on the page beside the agents panel
        script.write_text('wait-agents\ncmd settings\n' + f'click 955 {y}\n'
                          'wait-agents\nprint-agents\nquit\n')
        result = subprocess.run([str(EXE), str(self.project), '--headless', '1400x8000',
                                 '--scale', '1', '--script', str(script)], env=self.env,
                                capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b'Claude: Claude only\n')


    def test_models_in_the_row_and_where_replies_change(self):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        def claude(model, text):
            return json.dumps({'type': 'assistant', 'cwd': str(self.project), 'message': {
                'model': model, 'role': 'assistant', 'content': [{'type': 'text', 'text': text}]}}) + '\n'
        (directory / 'c.jsonl').write_text(json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {
            'role': 'user', 'content': 'Claude prompt'}}) + '\n' + claude('claude-opus-5-5', 'One') +
            claude('<synthetic>', 'A notice') + claude('claude-opus-5-5', 'Two') + claude('claude-sonnet-5-5', 'Three'))
        os.utime(directory / 'c.jsonl', (2000000000, 2000000000))
        def turn(model):
            return json.dumps({'type': 'turn_context', 'payload': {'cwd': str(self.project), 'model': model}}).encode() + b'\n'
        self.session.write_bytes(self.metadata() + b'\n' + turn('gpt-6.1-sol') + self.message('user', 'Codex prompt') +
                                 self.message('assistant', 'Alpha') + turn('gpt-6-astra') + self.message('assistant', 'Beta'))
        os.utime(self.session, (1900000000, 1900000000))
        rows = self.worker()[-1][2]
        self.assertEqual([(r['kind'], r['model']) for r in rows], [(1, 'claude-sonnet-5-5'), (2, 'gpt-6-astra')])
        self.assertEqual(self.run_commands(['print-agents 1']),
                         'Claude [model: claude-sonnet-5-5]: Claude prompt\n'
                         'Codex [model: gpt-6-astra]: Codex prompt\n'
                         'user Claude prompt\nagent(claude-opus-5-5) One\nagent A notice\nagent Two\n'
                         'agent(claude-sonnet-5-5) Three\n')
        self.assertEqual(self.run_commands(['print-agents 2']).split('\n', 2)[2],
                         'user Codex prompt\nagent(gpt-6.1-sol) Alpha\nagent(gpt-6-astra) Beta\n')


    def test_latest_model_of_a_long_log_between_its_first_and_last_windows(self):
        def turn(model):
            return json.dumps({'type': 'turn_context', 'payload': {'model': model}}).encode() + b'\n'
        def output(size):
            return json.dumps({'type': 'response_item', 'payload': {
                'type': 'function_call_output', 'call_id': 'c', 'output': 'o' * size}}).encode() + b'\n'
        self.session.write_bytes(self.metadata() + b'\n' + turn('gpt-old') + self.message('user', 'Long Codex') +
                                 output(300000) + turn('gpt-new') + self.message('assistant', 'Switched') +
                                 output(600000))
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        def reply(model):
            return json.dumps({'type': 'assistant', 'cwd': str(self.project), 'message': {
                'model': model, 'role': 'assistant', 'content': [{'type': 'text', 'text': model}]}}) + '\n'
        def result(size):
            return json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': 't', 'content': 'r' * size}]}}) + '\n'
        (directory / 'c.jsonl').write_text(json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {
            'role': 'user', 'content': 'Long Claude'}}) + '\n' + reply('claude-old') + result(300000) +
            reply('claude-new') + result(600000))
        rows = self.worker()[-1][2]
        self.assertEqual(sorted(r['model'] for r in rows), ['claude-new', 'gpt-new'])

    def test_model_switched_in_an_append_with_long_output_after_it(self):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        log = directory / 'c.jsonl'
        def reply(model):
            return json.dumps({'type': 'assistant', 'cwd': str(self.project), 'message': {
                'model': model, 'role': 'assistant', 'content': [{'type': 'text', 'text': model}]}}) + '\n'
        def result(size):
            return json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': 't', 'content': 'r' * size}]}}) + '\n'
        log.write_text(json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {
            'role': 'user', 'content': 'Appended'}}) + '\n' + reply('model-old') + result(300000))
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-old'])
        with log.open('a') as stream:
            stream.write(reply('model-new') + result(600000))
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-new'])
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-new'])

    def test_models_of_records_longer_than_a_read_window(self):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        log = directory / 'c.jsonl'
        def compact(record):
            return json.dumps(record, separators=(',', ':'))  # as Claude Code writes its log
        def reply(model, text):
            return compact({'type': 'assistant', 'cwd': str(self.project), 'message': {
                'model': model, 'role': 'assistant', 'content': [{'type': 'text', 'text': text}]}}) + '\n'
        prompt = compact({'type': 'user', 'cwd': str(self.project), 'message': {'role': 'user', 'content': 'Long'}}) + '\n'
        unfinished = compact({'type': 'user', 'cwd': str(self.project), 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': 't', 'content': 'r' * 600000}]}})
        # a log that ends inside a record longer than the last window
        log.write_text(prompt + reply('model-old', 'o' * 300000) + reply('model-new', 'short') + unfinished)
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-new'])
        with log.open('a') as stream:
            stream.write('\n')
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-new'])
        # a reply longer than a window: its beginning names the model
        log.write_text(prompt + reply('model-old', 'short') + reply('model-big', 'b' * 300000))
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-big'])
        # a long reply read while it was being written, then completed
        partial = reply('model-split', 'p' * 600000)
        log.write_text(prompt + reply('model-old', 'short') + partial[:200000])
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-old'])
        with log.open('a') as stream:
            stream.write(partial[200000:])
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-split'])
        # the model need not be its message's first key
        late = compact({'type': 'assistant', 'cwd': str(self.project), 'message': {
            'id': 'msg_late', 'role': 'assistant', 'model': 'model-late',
            'content': [{'type': 'text', 'text': 'l' * 300000}]}}) + '\n'
        log.write_text(prompt + reply('model-old', 'short') + late)
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-late'])
        # a subagent's reply inside a long progress record is not the session's model
        progress = compact({'type': 'progress', 'cwd': str(self.project), 'data': {'message': {
            'type': 'assistant', 'message': {'model': 'model-sub', 'content': [{'type': 'text', 'text': 's' * 300000}]}}}})
        log.write_text(prompt + reply('model-main', 'short') + progress + '\n')
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-main'])
        # a reply just longer than a window leaves few of its first bytes before the window's start
        body = 262200 - len(reply('model-edge', ''))
        log.write_text(prompt + reply('model-old', 'short') + reply('model-edge', 'e' * body) +
                       compact({'type': 'user', 'cwd': str(self.project), 'message': {'role': 'user', 'content': 'next'}}) + '\n')
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['model-edge'])

    def test_model_of_a_codex_turn_context_longer_than_a_read_window(self):
        def turn(model, instructions=''):
            payload = {'cwd': str(self.project), 'model': model}
            if instructions:
                payload['collaboration_mode'] = {'settings': {'developer_instructions': instructions}}
            # compact, as Codex writes its log
            return json.dumps({'type': 'turn_context', 'payload': payload}, separators=(',', ':')).encode() + b'\n'
        self.session.write_bytes(self.metadata() + b'\n' + turn('gpt-old') + self.message('user', 'Codex prompt') +
                                 self.message('assistant', 'Reply') + turn('gpt-big', 'i' * 300000) +
                                 self.message('user', 'Next'))
        self.assertEqual([r['model'] for r in self.worker()[-1][2]], ['gpt-big'])

    def test_a_synthetic_notice_takes_no_model_label(self):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        def record(model, content):
            return json.dumps({'type': 'assistant', 'cwd': str(self.project), 'message': {
                'model': model, 'role': 'assistant', 'content': content}}) + '\n'
        (directory / 'c.jsonl').write_text(json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {
            'role': 'user', 'content': 'Prompt'}}) + '\n' +
            record('claude-opus-5-5', [{'type': 'tool_use', 'name': 'Bash', 'input': {'command': 'ls'}}]) +
            record('<synthetic>', [{'type': 'text', 'text': 'API notice'}]) +
            record('claude-opus-5-5', [{'type': 'text', 'text': 'Real reply'}]))
        self.assertEqual(self.run_commands(['print-agents 1']).split('\n', 1)[1],
                         'user Prompt\ntool(Bash) ls\nagent API notice\nagent(claude-opus-5-5) Real reply\n')

    def test_closed_loaded_session_gets_latest_tail_title_without_regressing(self):
        self.assert_closed_loaded_title('Latest tail title')

    def test_repeated_custom_title_updates_a_closed_loaded_session(self):
        self.assert_closed_loaded_title('Prefix title')

    def test_replacement_resets_closed_loaded_title_and_messages(self):
        for latest in ('Replacement fallback', 'Prefix title'):
            with self.subTest(title=latest):
                self.assert_closed_loaded_title(latest, replace=True)

    def assert_closed_loaded_title(self, latest, replace=False):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / 'titles.jsonl'
        def title(text):
            return json.dumps({'type': 'custom-title', 'customTitle': text}) + '\n'
        long_message = json.dumps({'type': 'assistant', 'message': {
            'role': 'assistant', 'content': 'x' * 400000}}) + '\n'
        path.write_text(title('Prefix title') + long_message +
                        title('Full transcript title') + long_message)
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Prefix title')
        script = self.home / 'commands.rsc'
        script.write_text('wait-agents\nclick 1000 100\nclick 922 60\n'
                          'click 1258 60\nwait-agents\nprint-agents\nprint-project\n'
                          'wait 2000\nclick 1258 60\nwait-agents\nprint-agents\n' +
                          ('print-agents 1\n' if replace else '') + 'quit\n')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b'Claude: Full transcript title\n')
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            if replace:
                path.write_text(json.dumps({'type': 'user', 'cwd': str(self.project),
                    'message': {'role': 'user', 'content': latest}}) + '\n')
            else:
                with path.open('a') as stream:
                    stream.write(title(latest))
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            expected = 'Claude: ' + latest + '\n'
            if replace:
                expected += 'Claude: ' + latest + '\nuser ' + latest + '\n'
            self.assertEqual(output, expected.encode())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()

    @unittest.skipIf(sys.platform == 'win32', 'Windows locks running executable files')
    def test_discovery_survives_atomic_executable_replacement(self):
        import shutil
        executable = self.home / 'rhun-copy'
        shutil.copy2(EXE, executable)
        self.make_history(1)
        script = self.home / 'commands.rsc'
        script.write_text('print-agents\nprint-project\nwait 1500\n'
                          'click 1258 60\nwait-agents\nprint-agents-page\nprint-agents\nquit\n')
        process = subprocess.Popen([str(executable), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b'Codex: Session 0000\n')
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            replacement = executable.with_name('replacement')
            shutil.copy2(EXE, replacement)
            replacement.replace(executable)
            path = self.session.parent / 'new.jsonl'
            path.write_bytes(self.metadata() + b'\n' + self.message('user', 'After replacement'))
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'shown=2 total=2 loading=0 error=0\n'
                                     b'Codex: After replacement\nCodex: Session 0000\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()


    def test_tail_user_message_preserves_a_known_full_transcript_custom_title(self):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        path = directory / 'titles.jsonl'
        meta = json.dumps({'type': 'user', 'isMeta': True, 'message': {
            'role': 'user', 'content': 'x' * 300000}}) + '\n'
        message = json.dumps({'type': 'assistant', 'message': {
            'role': 'assistant', 'content': 'x' * 300000}}) + '\n'
        path.write_text(meta + json.dumps({'type': 'custom-title',
                                          'customTitle': 'Known custom title'}) + '\n' + message)
        self.assertEqual(self.worker()[-1][2][0]['title'], '')
        script = self.home / 'commands.rsc'
        script.write_text('wait-agents\nclick 1000 100\nclick 922 60\n'
                          'print-agents\nprint-project\nwait 1500\n'
                          'click 1258 60\nwait-agents\nprint-agents\nquit\n')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b'Claude: Known custom title\n')
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            with path.open('a') as stream:
                stream.write(json.dumps({'type': 'user', 'message': {
                    'role': 'user', 'content': 'Latest user message'}}) + '\n')
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'Claude: Known custom title\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()

    def test_claude_slug_collisions_use_recorded_worktree_cwd(self):
        self.init_repo()
        trees = [self.add_worktree(name) for name in ('feature-a', 'feature_a')]
        self.assertEqual(claude_slug(str(trees[0])), claude_slug(str(trees[1])))
        directory = self.home / '.claude/projects' / claude_slug(str(trees[0]))
        directory.mkdir(parents=True)
        for index, tree in enumerate(trees):
            (directory / f'session-{index}.jsonl').write_text(
                json.dumps({'type': 'queue-operation'}) + '\n' +
                json.dumps({'type': 'user', 'cwd': str(tree), 'message': {
                    'role': 'user', 'content': 'Session ' + tree.name}}) + '\n')
        for _ in range(2):   # cold and cached discovery
            rows = self.worker(sources='claude')[-1][2]
            self.assertEqual({(row['badge'], row['title']) for row in rows},
                             {(tree.name, 'Session ' + tree.name) for tree in trees})

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS read interposition')
    def test_cold_claude_cwd_failure_recovers_exact_worktree_identity(self):
        self.init_repo()
        trees = [self.add_worktree(name) for name in ('feature-a', 'feature_a')]
        directory = self.home / '.claude/projects' / claude_slug(str(trees[0]))
        directory.mkdir(parents=True)
        target = directory / 'session.jsonl'
        target.write_text(json.dumps({'type': 'user', 'cwd': str(trees[1]), 'message': {
            'role': 'user', 'content': 'Recovered identity'}}) + '\n')
        library = self.home / 'faults.dylib'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                        str(ROOT / 'tests/file_faults.c'), '-o', str(library)], check=True)
        self.env.update(DYLD_INSERT_LIBRARIES=str(library), RHUN_TEST_PATH=str(target),
                        RHUN_TEST_FAULT='read', RHUN_TEST_ERRNO='5')
        for row in self.worker(sources='claude')[-1][2]:
            self.assertEqual(row['badge'], trees[1].name)
        del self.env['DYLD_INSERT_LIBRARIES']
        rows = self.worker(sources='claude')[-1][2]
        self.assertEqual([(row['badge'], row['title']) for row in rows],
                         [(trees[1].name, 'Recovered identity')])

    def test_cached_custom_title_survives_large_appends_and_resets_on_rewrite(self):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        path = directory / 'titles.jsonl'
        def user(text):
            return json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {
                'role': 'user', 'content': text}}) + '\n'
        def message(size):
            return json.dumps({'type': 'assistant', 'message': {
                'role': 'assistant', 'content': 'x' * size}}) + '\n'
        original = user('Original fallback') + json.dumps({
            'type': 'custom-title', 'customTitle': 'Old prefix title'}) + '\n' + \
            message(300000) + json.dumps({
            'type': 'custom-title', 'customTitle': 'Known custom title'}) + '\n'
        path.write_text(original)
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Known custom title')
        with path.open('a') as stream:
            stream.write(message(300000))
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Known custom title')
        with path.open('a') as stream:
            stream.write(json.dumps({'type': 'custom-title',
                                     'customTitle': 'New custom title'}) + '\n')
        self.assertEqual(self.worker()[-1][2][0]['title'], 'New custom title')
        # A larger replacement is a rewrite, not an append to the original log.
        path.write_text(user('Replacement fallback') + message(900000))
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Replacement fallback')
        path.write_text(user('Truncated fallback'))
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Truncated fallback')
        path.write_text(json.dumps({'type': 'custom-title', 'customTitle': 'Complete title'}) +
                        '\n' + json.dumps({'type': 'custom-title', 'customTitle': 'Partial title'}))
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Complete title')
        with path.open('a') as stream:
            stream.write('\n')
        self.assertEqual(self.worker()[-1][2][0]['title'], 'Partial title')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS read interposition')
    def test_failed_title_read_is_retried_on_an_unchanged_file(self):
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        for index in range(51):
            path = directory / f'session-{index:04}.jsonl'
            path.write_text(json.dumps({'type': 'user', 'cwd': str(self.project), 'message': {
                'role': 'user', 'content': f'Claude {index:04}'}}) + '\n')
            os.utime(path, (1700000000 + index, 1700000000 + index))
        self.worker()
        library = self.home / 'faults.dylib'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                        str(ROOT / 'tests/file_faults.c'), '-o', str(library)], check=True)
        target = directory / 'session-0000.jsonl'
        self.env.update(DYLD_INSERT_LIBRARIES=str(library), RHUN_TEST_PATH=str(target),
                        RHUN_TEST_FAULT='read', RHUN_TEST_ERRNO='5')
        failed = self.worker(100)[-1][2][-1]
        self.assertEqual(failed['path'], str(target))
        self.assertEqual(failed['title'], '')
        self.assertEqual(failed['flags'] & 2, 0)
        del self.env['DYLD_INSERT_LIBRARIES']
        recovered = self.worker(100)[-1][2][-1]
        self.assertEqual(recovered['title'], 'Claude 0000')
        self.assertEqual(recovered['flags'] & 2, 2)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS write interposition')
    def test_delayed_snapshot_cannot_replace_a_newer_consumed_title(self):
        import time
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        path = directory / 'titles.jsonl'
        def title(text):
            return json.dumps({'type': 'custom-title', 'customTitle': text}) + '\n'
        path.write_text(title('Title X'))
        fixed_time = 2000000000000000000
        os.utime(path, ns=(fixed_time, fixed_time))
        library = self.home / 'faults.dylib'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-dynamiclib',
                        str(ROOT / 'tests/file_faults.c'), '-o', str(library)], check=True)
        ready = self.home / 'ready'
        self.env.update(DYLD_INSERT_LIBRARIES=str(library), RHUN_TEST_AGENT_DELAY_MS='2000',
                        RHUN_TEST_AGENT_READY=str(ready))
        script = self.home / 'commands.rsc'
        shot = self.home / 'actual.ppm'
        script.write_text('print-agents 1\nprint-project\nwait 3500\n' +
                          f'shot {shot}\nquit\n')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b'Claude: Title X\n')
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            ready.unlink()
            with path.open('a') as stream:
                stream.write(title('Title A'))
            os.utime(path, ns=(fixed_time, fixed_time))
            deadline = time.monotonic() + 5
            while not ready.exists():
                self.assertLess(time.monotonic(), deadline, 'worker did not reach publication')
                time.sleep(.01)
            # A is serialized in the worker, but still waiting to be published.
            with path.open('a') as stream:
                stream.write(title('Title B'))
            os.utime(path, ns=(fixed_time, fixed_time))
            _, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()
        del self.env['DYLD_INSERT_LIBRARIES']
        expected = self.home / 'expected.ppm'
        self.run_commands(['print-agents 1', f'shot {expected}'])
        def header_pixels(file):
            magic, dimensions, depth, pixels = file.read_bytes().split(b'\n', 3)
            self.assertEqual((magic, dimensions, depth), (b'P6', b'1280 800', b'255'))
            return b''.join(pixels[(y * 1280 + 940) * 3:(y * 1280 + 1190) * 3]
                            for y in range(40, 80))
        self.assertEqual(header_pixels(shot), header_pixels(expected))

    def test_reopening_panel_refreshes_hidden_changes_immediately(self):
        self.make_history(1)
        script = self.home / 'commands.rsc'
        script.write_text('print-agents\ncmd toggle_agents\nwait 100\nprint-project\n'
                          'wait 1200\ncmd toggle_agents\nwait-agents\nprint-agents-page\n'
                          'print-agents\nquit\n')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b'Codex: Session 0000\n')
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            new_directory = self.home / '.codex/sessions/2025/01/01'
            new_directory.mkdir(parents=True)
            (new_directory / 'new.jsonl').write_bytes(self.metadata() + b'\n' +
                                                      self.message('user', 'Hidden session'))
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'shown=2 total=2 loading=0 error=0\n'
                                     b'Codex: Hidden session\nCodex: Session 0000\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()

    def test_live_config_reload_changes_worker_sources(self):
        self.make_history(1)
        directory = self.home / '.claude/projects' / claude_slug(str(self.project))
        directory.mkdir(parents=True)
        (directory / 'c.jsonl').write_text(json.dumps({'type': 'user', 'cwd': str(self.project),
            'message': {'role': 'user', 'content': 'Claude only'}}) + '\n')
        script = self.home / 'commands.rsc'
        script.write_text('print-agents\nprint-project\nwait 1500\nprint-agents\nquit\n')
        process = subprocess.Popen([str(EXE), str(self.project), '--headless', '1280x800',
                                    '--scale', '1', '--script', str(script)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual({process.stdout.readline(), process.stdout.readline()},
                             {b'Codex: Session 0000\n', b'Claude: Claude only\n'})
            self.assertTrue(process.stdout.readline().startswith(b'project='))
            config = self.home / 'config/rhun/config'
            config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n'
                              '[agents]\nclaude = true\ncodex = false\ngrok = false\nopencode = false\n')
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'Claude: Claude only\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
            process.stdout.close()
            process.stderr.close()


class GrokDiscovery(unittest.TestCase):
    """Grok Build keeps a session in ~/.grok/sessions/<its cwd, URL-encoded>/<session id>/: the log of
    the conversation, updates.jsonl, and summary.json with the cwd and the title Grok gives it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='rhun-grok-')
        self.home = Path(self.tmp.name).resolve()
        self.project = self.home / 'project café with spaces'
        self.project.mkdir()
        self.env = dict(os.environ, HOME=self.home.as_posix(),
                        XDG_CONFIG_HOME=(self.home / 'config').as_posix(),
                        XDG_STATE_HOME=(self.home / 'state').as_posix(), SHELL='/nonexistent')
        self.env.pop('GROK_HOME', None)
        self.config('')
        self.count = 0

    def tearDown(self):
        self.tmp.cleanup()

    def config(self, extra):
        config = self.home / 'config/rhun/config'
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text('[updates]\ncheck = false\n[git]\nenabled = false\n' + extra, encoding='utf-8')

    def session(self, *updates, cwd=None, title=None, kind=None, grok_home=None, when=None):
        cwd = cwd or self.project.as_posix()
        self.count += 1
        sid = f'01a11c1e-808b-7263-a007-{self.count:012}'
        folder = (grok_home or self.home / '.grok') / 'sessions' / quote(cwd, safe='') / sid
        folder.mkdir(parents=True)
        summary = {'info': {'id': sid, 'cwd': cwd}, 'session_summary': title or '',
                   'created_at': '2026-10-08T15:25:23.498980Z', 'num_messages': len(updates)}
        if title:
            summary['generated_title'] = title
        if kind:
            summary['session_kind'] = kind
        (folder / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
        log = folder / 'updates.jsonl'
        log.write_bytes(b''.join(self.update(sid, update) for update in updates))
        if when is not None:
            os.utime(log, (when, when))
        return log

    @staticmethod
    def update(sid, update):
        record = {'timestamp': 1791473123, 'method': 'session/update',
                  'params': {'sessionId': sid, 'update': update}}
        return json.dumps(record, ensure_ascii=False).encode('utf-8') + b'\n'

    @staticmethod
    def user(text):
        return {'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': text},
                '_meta': {'modelId': 'grok-4.7', 'promptIndex': 0}}

    @staticmethod
    def agent(text):
        return {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': text}}

    @staticmethod
    def tool(call, name, raw_input):
        return {'sessionUpdate': 'tool_call', 'toolCallId': call, 'title': name, 'rawInput': raw_input,
                '_meta': {'x.ai/tool': {'version': 1, 'name': name}}}

    @staticmethod
    def result(call, text=None, diff=None, status='completed'):
        content = []
        if text is not None:
            content.append({'type': 'content', 'content': {'type': 'text', 'text': text}})
        if diff is not None:
            content.append({'type': 'diff', 'path': diff[0], 'oldText': diff[1], 'newText': diff[2]})
        return {'sessionUpdate': 'tool_call_update', 'toolCallId': call, 'status': status,
                'content': content}

    def run_commands(self, commands, timeout=20):
        script = self.home / 'commands.rsc'
        script.write_text('\n'.join(commands + ['quit']) + '\n', encoding='utf-8')
        result = subprocess.run([str(EXE), str(self.project), '--headless', '1280x800',
                                 '--scale', '1', '--script', str(script)], env=self.env,
                                capture_output=True, timeout=timeout)
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace'))
        return result.stdout.decode('utf-8')

    def worker(self, sources='claude,codex,grok'):
        result = subprocess.run([str(EXE), '--agent-index', str(self.project), '50', sources],
                                env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        offset = 0
        page = None
        while offset < len(result.stdout):
            payload, = struct.unpack_from('<Q', result.stdout, offset + 24)
            page = CodexDiscovery.decode_records(result.stdout[offset:offset + 32 + payload])
            offset += 32 + payload
        return [(row['kind'], row['title']) for row in page]

    def test_thread_shows_prompts_replies_tools_and_results(self):
        calc = (self.project / 'calc.py').as_posix()
        self.session(
            {'sessionUpdate': 'current_mode_update', 'currentModeId': 'default'},
            self.user('calc.py has a bug in add(). Fix it.'),
            {'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'Thinking'}},
            self.agent("I'll look at `calc.py` first."),
            self.tool('c0', 'read_file', {'target_file': calc}),
            {'sessionUpdate': 'tool_call_update', 'toolCallId': 'c0', 'kind': 'read',
             'title': 'Read `calc.py`', 'rawInput': {'variant': 'ReadFile', 'target_file': calc}},
            self.tool('c1', 'run_terminal_command', {'command': 'ls -1', 'description': 'List files'}),
            self.result('c0', '1→def add(a, b):\n    return a - b\n'),
            self.result('c1', '\x1b[1m\x1b[36mcalc.py\x1b[39;49m\x1b[0m\n'),
            self.tool('c2', 'search_replace', {'file_path': calc, 'old_string': 'a - b',
                                               'new_string': 'a + b'}),
            self.result('c2', diff=(calc, '    return a - b', '    return a + b')),
            self.tool('c3', 'list_dir', {'target_directory': (self.project / 'src').as_posix()}),
            self.result('c3'),
            self.tool('c4', 'read_file', {'target_file': 'missing.txt'}),
            self.result('c4', 'Error: missing.txt does not exist.', status='failed'),
            {'sessionUpdate': 'turn_completed', 'stop_reason': 'end_turn'},
            self.agent('`add()` returns `a + b` now.'))
        self.assertEqual(self.run_commands(['print-agents 1']),
                         'Grok: calc.py has a bug in add(). Fix it.\n'
                         'user calc.py has a bug in add(). Fix it.\n'
                         "agent(grok-4.7) I'll look at `calc.py` first.\n"
                         'tool(read_file) calc.py\n'
                         'tool(run_terminal_command) ls -1\n'
                         'result 1→def add(a, b):\n'
                         'result calc.py\n'
                         'tool(search_replace) calc.py\n'
                         'result return a + b\n'
                         'tool(list_dir) src\n'
                         'tool(read_file) missing.txt\n'
                         'result Error: missing.txt does not exist.\n'
                         'agent `add()` returns `a + b` now.\n')

    def test_grok_titles_its_sessions_and_a_rename_follows_without_new_log_lines(self):
        log = self.session(self.user('Fix the add function'), title='Fix bug in calc.py add')
        self.session(self.user('Untitled yet'), when=1700000000)
        self.assertEqual(self.worker(), [(3, 'Fix bug in calc.py add'), (3, 'Untitled yet')])
        # /rename rewrites summary.json alone; the log is the same
        summary = log.parent / 'summary.json'
        data = json.loads(summary.read_text(encoding='utf-8'))
        data.update(generated_title='Custom probe title', title_is_manual=True)
        stamp = log.stat()
        summary.write_text(json.dumps(data), encoding='utf-8')
        self.assertEqual(log.stat().st_mtime_ns, stamp.st_mtime_ns)
        self.assertEqual(self.worker(), [(3, 'Custom probe title'), (3, 'Untitled yet')])
        self.assertEqual(self.run_commands(['print-agents']),
                         'Grok: Custom probe title\nGrok: Untitled yet\n')

    def test_sessions_without_a_prompt_and_subagents_are_not_listed(self):
        # The interface makes a session's folder and log when it starts, before any prompt
        empty = self.session({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'})
        self.session(self.user('Read hello.txt and report it'), kind='subagent',
                     title='Read hello.txt and report exact contents')
        # A session folder that has no log yet, and other files of the cwd's folder
        (empty.parent.parent / '01a11c1e-808b-7263-a007-999999999999').mkdir()
        (empty.parent.parent / 'prompt_history.jsonl').write_text('{}\n', encoding='utf-8')
        self.assertEqual(self.worker(), [])
        self.assertEqual(self.worker(), [])  # as cached
        with empty.open('ab') as stream:
            stream.write(self.update('x', self.user('Now with a prompt')))
        self.assertEqual(self.worker(), [(3, 'Now with a prompt')])

    def test_summary_written_later_and_other_cwds(self):
        log = self.session(self.user('Waiting for its summary'))
        summary = log.parent / 'summary.json'
        saved = summary.read_bytes()
        summary.write_bytes(saved[:20])          # being written
        other = self.home / 'other'
        other.mkdir()
        self.session(self.user('Another project'), cwd=other.as_posix())
        self.assertEqual(self.worker(), [])
        summary.write_bytes(saved)
        self.assertEqual(self.worker(), [(3, 'Waiting for its summary')])

    def test_sources_setting_and_grok_home(self):
        self.session(self.user('In the default home'))
        self.assertEqual(self.worker(sources='claude,codex'), [])
        custom = self.home / 'custom grok'
        self.session(self.user('In GROK_HOME'), grok_home=custom)
        self.assertEqual(self.worker(), [(3, 'In the default home')])
        self.env['GROK_HOME'] = custom.as_posix()
        self.assertEqual(self.worker(), [(3, 'In GROK_HOME')])
        self.config('[agents]\nsources = claude codex\n[ui]\ndark_theme = rhun-dark\n')
        self.assertEqual(self.run_commands(['print-agents']), '')
        self.config('[agents]\nsources = grok\n')
        self.assertEqual(self.run_commands(['print-agents']), 'Grok: In GROK_HOME\n')

    def test_configs_from_before_grok_build_get_it(self):
        # sources was written with every setting, so the old default is in every older config; a config
        # written since (it has dark_theme) keeps what it says
        self.session(self.user('Listed'))
        self.config('[ui]\ntheme = rhun-light\n[agents]\nsources = claude codex\n')
        self.assertEqual(self.run_commands(['print-agents']), 'Grok: Listed\n')
        self.config('[agents]\nsources = claude codex\n')
        self.assertEqual(self.run_commands(['print-agents']), 'Grok: Listed\n')
        self.config('[ui]\ntheme = rhun-light\n[agents]\nsources = codex claude\n')
        self.assertEqual(self.run_commands(['print-agents']), '')
        self.config('[ui]\ntheme = rhun-light\ndark_theme = rhun-dark\n[agents]\nsources = claude codex\n')
        self.assertEqual(self.run_commands(['print-agents']), '')


    def test_current_model_in_the_row_and_the_prompt_model_on_replies(self):
        log = self.session(self.user('Grok prompt'), self.agent('Grok reply'), title='Models')
        summary = log.parent / 'summary.json'
        data = json.loads(summary.read_text())
        data['current_model_id'] = 'grok-4.7-fast'
        summary.write_text(json.dumps(data))
        self.assertEqual(self.run_commands(['print-agents 1']),
                         'Grok [model: grok-4.7-fast]: Models\nuser Grok prompt\nagent(grok-4.7) Grok reply\n')

    def test_worktree_sessions_have_its_badge(self):
        def git(*args):
            subprocess.run(['git', '-C', str(self.project), *args], env=self.env, check=True,
                           capture_output=True)
        git('init', '-q', '-b', 'main')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
            'commit', '--allow-empty', '-qm', 'Initial')
        worktree = self.home / 'fix café 🦉'
        git('worktree', 'add', '--detach', str(worktree))
        self.session(self.user('In the worktree'), cwd=worktree.as_posix(), when=2000000000)
        self.session(self.user('In the main checkout'), when=1900000000)
        self.assertEqual(self.run_commands(['print-agents 1']),
                         f'Grok [worktree: {worktree.name}]: In the worktree\n'
                         'Grok: In the main checkout\n'
                         'user In the worktree\n')

    def test_open_session_follows_new_lines(self):
        log = self.session(self.user('Live session'))
        script = self.home / 'commands.rsc'
        script.write_text('print-agents 1\nwait 2000\nprint-agents 1\nquit\n', encoding='utf-8')
        process = subprocess.Popen([str(EXE), self.project.as_posix(), '--headless', '1000x700',
                                    '--script', script.as_posix()], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.stdout.readline(), b'Grok: Live session\n')
            self.assertEqual(process.stdout.readline(), b'user Live session\n')
            with log.open('ab') as stream:
                stream.write(self.update('x', self.tool('c0', 'run_terminal_command', {'command': 'make'})))
                stream.write(self.update('x', self.agent('A live update')))
            output, errors = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, errors)
            self.assertEqual(output, b'Grok: Live session\nuser Live session\n'
                                     b'tool(run_terminal_command) make\nagent(grok-4.7) A live update\n')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == '__main__':
    unittest.main()
