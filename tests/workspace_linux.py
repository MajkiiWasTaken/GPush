#!/usr/bin/env python3
"""Exercise real GPush menus in a Linux PTY with disposable Git repositories."""
import codecs
import errno
import fcntl
import os
import pathlib
import pty
import select
import signal
import shlex
import shutil
import struct
import subprocess
import tempfile
import termios
import time

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'linux' / 'gp'


class Terminal:
    def __init__(self, args, env, cwd, controlling=False):
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 28, 100, 0, 0))
        def set_controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.controlling = controlling
        self.child = subprocess.Popen(['bash', str(SCRIPT), *args], stdin=slave,
                                      stdout=slave, stderr=slave, env=env, cwd=cwd,
                                      preexec_fn=set_controlling_terminal if controlling else None)
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

    def finish(self, expected=0):
        deadline = time.monotonic() + 12
        try:
            while self.read(deadline):
                pass
            assert self.child.wait(timeout=3) == expected, self.buffer[-1200:]
        finally:
            self.close()

    def close(self):
        if self.child.poll() is None:
            if self.controlling:
                os.killpg(self.child.pid, signal.SIGKILL)
            else:
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
    c.expect('> '); c.send(' ')
    c.expect('MARKED  2'); c.send('\r')
    c.expect('Selected files (2)'); c.expect('Commit message: '); c.send('\n')
    c.finish()
    assert git('log', '-1', '--format=%s', cwd=repo) == 'Add Unicode file'
    print('PASS application-mode arrows, multiple selections, cancellation')

    (repo/'fresh.txt').write_text('fresh data\n')
    c = open_menu('diff', str(repo))
    c.expect('Type to filter'); c.send('fresh')
    c.expect('1 / 3'); c.send('\r')
    c.expect('+fresh data'); c.expect('Esc: back'); c.send('\x1b')
    c.expect('Type to filter'); c.send('b.txt')
    c.expect('1 / 3'); c.send('\r'); c.expect('Staged changes'); c.expect('+b changed')
    c.expect('Esc: back'); c.send('\x1b'); c.expect('Type to filter'); c.send('\x1b')
    c.finish()
    print('PASS staged and untracked diff selection')

    c = open_menu()
    c.expect('Type to filter'); c.send('\x1bOB')
    c.expect('> Repositories / commit and push'); c.send('\r')
    c.expect('Select repository'); c.expect('Type to filter'); c.send('Test [')
    c.expect('1 / 2'); c.send('\r'); c.expect('Repository / Test [project]')
    c.expect('Push committed changes only'); c.expect('Type to filter'); c.send('\x1b')
    c.expect('Interactive workspace'); c.expect('Type to filter'); c.send('\x1b'); c.finish()
    print('PASS repository picker and Escape navigation')

    c = open_menu()
    c.expect('Type to filter'); c.send('\x1bOB'); c.expect('> Repositories / commit and push'); c.send('\r')
    c.expect('Select repository'); c.expect('Repository      |  Path')
    c.expect('Other           |  '); c.expect('Test [project]  |  ')
    c.expect('Type to filter'); c.send('Test ['); c.expect('1 / 2'); c.send('\r')
    c.expect('Repository / Test [project]'); c.expect('Type to filter'); c.send('Status and recent'); c.expect('1 / 12'); c.send('\r')
    c.expect('Repository detail'); c.expect('[Q/Esc] Back'); c.send('\x1b'); c.expect('Type to filter')
    c.send('Commit graph'); c.expect('1 / 12'); c.send('\r'); c.expect('Esc  Back    Ctrl+C  Exit'); c.send(' ')
    c.send('\r'); time.sleep(0.2); c.send('\x03'); c.expect('Exit GPush?'); c.send('n'); c.send('\x1b'); c.expect('Repository / Test [project]'); c.expect('Type to filter')
    time.sleep(0.2); c.send('\x03'); c.expect('Exit GPush?'); c.send('n'); c.expect('Type to filter'); time.sleep(0.2); c.send('\x03'); c.expect('Exit GPush?'); c.send('\x03'); c.finish(expected=130)
    print('PASS aligned repository columns, persistent results, Ctrl+C cancel and exit')

    c = open_menu(); c.expect('Type to filter'); c.send('\x1b[A'); c.expect('> Exit')
    c.send('\x1b[B'); c.expect('> Workspace overview'); c.expect('Type to filter'); c.send('\x1b'); c.finish()
    print('PASS cyclic keyboard navigation')

    c = open_menu(); c.expect('Made by: Michal Švrček'); c.expect('Type to filter')
    fcntl.ioctl(c.master, termios.TIOCSWINSZ, struct.pack('HHHH', 16, 60, 0, 0))
    c.expect('Made by: Michal Švrček'); c.expect('Type to filter')
    c.send('\x1b[A'); c.expect('> Exit'); c.expect('Type to filter')
    fcntl.ioctl(c.master, termios.TIOCSWINSZ, struct.pack('HHHH', 34, 100, 0, 0))
    c.expect('###  ####'); c.expect('> Exit'); c.expect('Type to filter')
    c.send('\x1b[B'); c.expect('> Workspace overview'); c.expect('Type to filter')
    c.send('\x1b'); c.finish()
    print('PASS automatic terminal resize, logo visibility and stable last page')

    result = run('bash', str(SCRIPT), 'stats', '30')
    assert 'Commits  4' in result.stdout, result.stdout
    assert 'Test [project]' in result.stdout and 'Other' in result.stdout, result.stdout
    c = open_menu(); c.expect('Type to filter'); c.send('Development statistics'); c.expect('1 / 11'); c.send('\r')
    c.expect('Development activity / 30 days'); c.expect('Left/Right  Range'); c.send('a')
    c.expect('Cached local statistics'); c.expect('Left/Right  Range'); c.send('\x1b[D')
    c.expect('Development activity / 7 days'); c.expect('Left/Right  Range'); c.send('\x1b'); c.expect('Type to filter'); c.send('\x1b'); c.finish()
    print('PASS statistics totals, cached redraw and time range')

    # A real controlling PTY converts Ctrl+C into SIGINT during a native operation.
    slow_bin=base/'slow-bin'; slow_bin.mkdir()
    slow_git=slow_bin/'git'; marker=base/'fetch-started'
    real_git=shutil.which('git')
    slow_git.write_text('#!/bin/sh\nfor arg in "$@"; do\n  if [ "$arg" = fetch ]; then\n    touch '+shlex.quote(str(marker))+'\n    exec sleep 30\n  fi\ndone\nexec '+shlex.quote(real_git)+' "$@"\n')
    slow_git.chmod(0o755)
    slow_env=dict(env,PATH=str(slow_bin)+os.pathsep+env['PATH'])
    c=Terminal([],slow_env,base,controlling=True)
    try:
        c.expect('Type to filter'); c.send('Repositories'); c.expect('1 / 11'); c.send('\r')
        c.expect('Type to filter'); c.send('Test ['); c.expect('1 / 2'); c.send('\r')
        c.expect('Type to filter'); c.send('Fetch remote'); c.expect('1 / 12'); c.send('\r')
        deadline=time.monotonic()+5
        while not marker.exists() and time.monotonic()<deadline: time.sleep(0.05)
        assert marker.exists(), 'slow fetch did not start'
        c.send('\x03'); c.expect('Operation cancelled by user.'); c.expect('Esc  Back'); c.send('\x1b')
        c.expect('Repository / Test [project]'); c.expect('Type to filter'); c.send('\x1b')
        c.expect('Interactive workspace'); c.expect('Type to filter'); c.send('\x1b'); c.finish()
    except Exception:
        c.close(); raise
    print('PASS Ctrl+C cancels active fetch without closing workspace')

    # Fake release metadata only: decline the offer before downloading any package.
    bin_dir = base/'mock-bin'; bin_dir.mkdir()
    curl = bin_dir/'curl'
    curl.write_text("#!/bin/sh\nprintf '%s\\n' '{\"tag_name\":\"v99.0.0\",\"assets\":[{\"name\":\"GPush-linux.tar.gz\",\"browser_download_url\":\"https://example.invalid/package\"}]}'\n")
    curl.chmod(0o755)
    env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']
    c = open_menu(); c.expect('Type to filter'); c.send('Software update'); c.expect('1 / 11'); c.send('\r')
    c.expect('Software update'); c.expect('Type to filter'); c.send('\r'); c.expect('Download and install v99.0.0?'); c.send('n\n')
    c.expect('Esc  Back    Ctrl+C  Exit'); c.send('\x1b'); c.expect('Check for updates'); c.expect('Type to filter'); c.send('\x1b'); c.expect('Interactive workspace'); c.expect('Type to filter'); c.send('\x1b'); c.finish()
    assert "Run 'gp update' to install." in run('bash', str(SCRIPT), 'update', 'check').stdout
    print('PASS interactive update offer and unchanged CLI check')

    result = run('bash', str(SCRIPT), 'all', 'status', check=False)
    assert result.returncode == 1 and 'Test [project]' in result.stdout  # Other has no remote.
    assert 'main' in run('bash', str(SCRIPT), 'repo', 'status', str(repo)).stdout
    print('PASS classic CLI status and bulk dashboard')

    # Real two-repository bulk sync: verify exactly one fetch per repository.
    clean_config=base/'bulk-config'; clean_cache=base/'bulk-cache'
    bulk_env=dict(env, XDG_CONFIG_HOME=str(clean_config), XDG_CACHE_HOME=str(clean_cache))
    bulk_repos=[]
    for index in range(2):
        local=base/f'Bulk project {index}'
        bare=base/f'bulk-{index}.git'
        git('init', '--bare', str(bare))
        git('init', '-b', 'main', str(local))
        git('config', 'user.email', 'test@example.invalid', cwd=local)
        git('config', 'user.name', 'Test', cwd=local)
        (local/'tracked.txt').write_text('initial\n')
        git('add', '.', cwd=local); git('commit', '-m', 'Initial', cwd=local)
        git('remote', 'add', 'origin', str(bare), cwd=local)
        git('push', '-u', 'origin', 'main', cwd=local)
        (local/'tracked.txt').write_text('changed\n')
        git('commit', '-am', 'Local update', cwd=local)
        subprocess.run(['bash',str(SCRIPT),'cache','add',str(local)],env=bulk_env,check=True,stdout=subprocess.DEVNULL)
        bulk_repos.append((local,bare))
    count_bin=base/'count-bin';count_bin.mkdir()
    count_log=base/'fetch-count'
    count_git=count_bin/'git'
    count_git.write_text('#!/bin/sh\nfor arg in "$@"; do\n  if [ "$arg" = fetch ]; then printf "%s\\n" "$PWD" >> '+shlex.quote(str(count_log))+'; fi\ndone\nexec '+shlex.quote(real_git)+' "$@"\n')
    count_git.chmod(0o755)
    bulk_env['PATH']=str(count_bin)+os.pathsep+env['PATH']
    result=subprocess.run(['bash',str(SCRIPT),'all','sync','--allow-protected'],env=bulk_env,check=True,text=True,capture_output=True)
    assert len(count_log.read_text().splitlines())==2, count_log.read_text()
    for local,bare in bulk_repos:
        assert git('rev-parse','HEAD',cwd=local)==git('--git-dir',str(bare),'rev-parse','main')
    print('PASS parallel fetch stage, one fetch per repository, sequential safe push')

    # Exercise the exact width-aware table function at multiple terminal widths.
    script_text=SCRIPT.read_text()
    function=script_text.split('bulk_table_line() {',1)[1].split('\n}',1)[0]
    for width in (20, 39, 54, 55, 79, 100, 139):
        cmd='bulk_table_line() {'+function+'\n}\nbulk_width='+str(width)+"\nbulk_table_line 'Very long repository name' 'feature/long-branch-name' 'Long commit subject' 12 3 clean 'Up to date' 'OK fetched'"
        line=run('bash','-c',cmd).stdout.rstrip('\n')
        assert len(line)<=width,(width,line)
        assert 'OK' in line,(width,line)
    print('PASS adaptive bulk table widths 20-139 columns')



if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='gpush-workspace-') as directory:
        test(pathlib.Path(directory))
