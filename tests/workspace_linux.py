#!/usr/bin/env python3
"""Exercise real GPush menus in a Linux PTY with disposable Git repositories."""
import codecs
import errno
import fcntl
import os
import pathlib
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'linux' / 'gp'


class Terminal:
    def __init__(self, args, env, cwd):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 28, 100, 0, 0))
        self.child = subprocess.Popen(['bash', str(SCRIPT), *args], stdin=slave,
                                      stdout=slave, stderr=slave, env=env, cwd=cwd)
        os.close(slave)
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.buffer = ''

    def read(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([self.master], [], [], remaining)[0]:
            raise TimeoutError(self.buffer[-1200:])
        try:
            data = os.read(self.master, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b''
        if not data:
            return False
        self.buffer += self.decoder.decode(data)
        return True

    def expect(self, text):
        deadline = time.monotonic() + 12
        while text not in self.buffer:
            if not self.read(deadline):
                raise AssertionError(f'Missing {text!r}: {self.buffer[-1200:]}')
        self.buffer = self.buffer.split(text, 1)[1]

    def send(self, text):
        os.write(self.master, text.encode('utf-8'))

    def finish(self):
        deadline = time.monotonic() + 12
        try:
            while self.read(deadline):
                pass
            assert self.child.wait(timeout=3) == 0, self.buffer[-1200:]
        finally:
            self.close()

    def close(self):
        if self.child.poll() is None:
            self.child.kill()
            self.child.wait()
        os.close(self.master)


def test(base):
    env = os.environ.copy()
    env.update(HOME=str(base/'home'), XDG_CONFIG_HOME=str(base/'config'),
               XDG_CACHE_HOME=str(base/'cache'), TERM='xterm-256color',
               GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               LANG='C.UTF-8', NO_COLOR='1')
    (base/'home').mkdir()

    def run(*args, cwd=base, check=True):
        return subprocess.run(args, cwd=cwd, env=env, check=check, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def git(*args, cwd=base):
        return run('git', *args, cwd=cwd).stdout.strip()

    def open_menu(*args):
        return Terminal(args, env, base)

    repo, other, remote = base/'Test [project]', base/'Other', base/'remote.git'
    git('init', '--bare', str(remote))
    for root in (repo, other):
        root.mkdir()
        git('init', '-b', 'main', cwd=root)
        git('config', 'user.email', 'test@example.invalid', cwd=root)
        git('config', 'user.name', 'Test', cwd=root)
        (root/'a.txt').write_text('a\n')
        (root/'b.txt').write_text('b\n')
        git('add', '.', cwd=root)
        git('commit', '-m', 'Initial', cwd=root)
        run('bash', str(SCRIPT), 'cache', 'add', str(root))
    git('remote', 'add', 'origin', str(remote), cwd=repo)
    git('push', '-u', 'origin', 'main', cwd=repo)
    (repo/'a.txt').write_text('a changed\n')
    (repo/'b.txt').write_text('b changed\n')
    git('add', 'b.txt', cwd=repo)
    new_file = 'č nový [soubor].txt'
    (repo/new_file).write_text('new content\n')

    c = open_menu('commit', str(repo))
    c.expect('Enter Confirm'); c.send('\r')
    c.expect('Selected files (1)'); c.expect('a.txt')
    c.expect('Commit message: '); c.send('Selected a only\n')
    c.expect('Commit selected working-tree versions?'); c.send('y\n')
    c.expect('Push committed changes now'); c.send('y\n')
    c.expect('Allow pushing to protected branches?'); c.send('y\n')
    c.finish()
    assert git('show', '--format=', '--name-only', 'HEAD', cwd=repo) == 'a.txt'
    assert git('diff', '--cached', '--name-only', cwd=repo) == 'b.txt'
    assert (repo/new_file).exists()
    assert git('rev-parse', 'HEAD', cwd=repo) == git('--git-dir', str(remote), 'rev-parse', 'main')
    print('PASS selected commit and push with unrelated staged/untracked files')

    c = open_menu('commit', str(repo))
    c.expect('Enter Confirm'); c.send('/')
    c.expect('Search (empty resets): '); c.send('nový\n')
    c.expect('1 / 2'); c.send(' ')
    c.expect('MARKED  1'); c.send('\r')
    c.expect('Selected files (1)'); c.expect(new_file)
    c.expect('Commit message: '); c.send('Add Unicode file\n')
    c.expect('Commit selected working-tree versions?'); c.send('y\n')
    c.expect('Push committed changes now'); c.send('n\n')
    c.finish()
    assert git('-c', 'core.quotePath=false', 'show', '--format=', '--name-only', 'HEAD', cwd=repo) == new_file
    assert git('diff', '--cached', '--name-only', cwd=repo) == 'b.txt'
    print('PASS filtered selection and Unicode filename')

    (repo/'a.txt').write_text('a third\n')
    c = open_menu('commit', str(repo))
    c.expect('Enter Confirm'); c.send(' ')
    c.expect('MARKED  1'); c.send('\x1bOB')
    c.expect('POSITION  2 / 2'); c.send(' ')
    c.expect('MARKED  2'); c.send('\r')
    c.expect('Selected files (2)'); c.expect('Commit message: '); c.send('\n')
    c.finish()
    assert git('log', '-1', '--format=%s', cwd=repo) == 'Add Unicode file'
    print('PASS application-mode arrows, multiple selections, cancellation')

    (repo/'fresh.txt').write_text('fresh data\n')
    c = open_menu('diff', str(repo))
    c.expect('Type to filter'); c.send('fresh')
    c.expect('1 / 3'); c.send('\r')
    c.expect('+fresh data'); c.expect('Esc/Enter: back'); c.send('\x1b')
    c.expect('Type to filter'); c.send('b.txt')
    c.expect('1 / 3'); c.send('\r'); c.expect('Staged changes'); c.expect('+b changed')
    c.expect('Esc/Enter: back'); c.send('\x1b'); c.expect('Type to filter'); c.send('\x1b')
    c.finish()
    print('PASS staged and untracked diff selection')

    c = open_menu()
    c.expect('Type to filter'); c.send('\x1bOB')
    c.expect('POSITION  2 / 11'); c.send('\r')
    c.expect('Select repository'); c.expect('Type to filter'); c.send('Test [')
    c.expect('1 / 2'); c.send('\r'); c.expect('Repository / Test [project]')
    c.expect('Push committed changes only'); c.expect('Type to filter'); c.send('\x1b')
    c.expect('Interactive workspace'); c.expect('Type to filter'); c.send('\x1b'); c.finish()
    print('PASS repository picker and Escape navigation')

    result = run('bash', str(SCRIPT), 'all', 'status', check=False)
    assert result.returncode == 1 and 'Test [project]' in result.stdout  # Other has no remote.
    assert 'main' in run('bash', str(SCRIPT), 'repo', 'status', str(repo)).stdout
    print('PASS classic CLI status and bulk dashboard')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='gpush-workspace-') as directory:
        test(pathlib.Path(directory))
