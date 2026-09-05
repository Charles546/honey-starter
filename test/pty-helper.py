#!/usr/bin/env python3
"""pty-helper.py - hermetic pty harness for the INTERACTIVE paths of
scripts/setup.sh (the branch-3 directory prompt and the invalid-model die).

setup.sh prompts open /dev/tty explicitly, so a pipe/stdin cannot satisfy
them; the CI/sandbox host has no `script`/`expect`, so a tiny python pty is
used. The helper inherits the caller's environment (set vars on the python3
invocation), spawns the child under a pty, waits for a prompt substring,
writes the answer lines, then prints "<RC>\\n<output>" once the child exits.

The helper drives the CHILD through a real controlling pty. Every answer line
is written to the pty input queue as soon as the first prompt substring is
seen; the child's `read -r` calls consume them serially (later prompts read
the already-buffered lines), which is how a multi-prompt questionnaire is
satisfied. An empty argument writes a blank line (Enter = accept default).

Modes:
  * --standalone SCRIPT PROMPT LINES... -- ARGS...
        Copies SCRIPT to a temp dir and runs `bash <tmp>/setup.sh ARGS`. The
        copy has NO valid honey-starter tree next to it, so detect_mode()
        reports the BOOTSTRAP copy -- the same code path a standalone / piped
        `curl ... | bash -s` run takes (BASH_SOURCE is resolved; the installed
        tree check fails). This is the robust, pipe-free way to exercise the
        bootstrap branch including the branch-3 directory prompt.
  * --on-disk    SCRIPT PROMPT LINES... -- ARGS...
        Runs `bash SCRIPT ARGS` (SCRIPT inside a tree) so detect_mode() sees
        the ON-DISK copy (used for the interactive questionnaire / model die).

ARGUMENTS after `--` are forwarded to the bash invocation. Exit status is the
child's real exit code (124 on timeout).
"""
import os, pty, sys, time, select, fcntl, termios, signal, tempfile, shutil


def run(script_path, prompt, lines, args):
    data = open(script_path, 'rb').read()
    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.close(slave)
        os.execvp('bash', ['bash', script_path] + args)
    os.close(slave)

    out = b''

    def drain(t=0.3):
        nonlocal out
        end = time.time() + t
        while time.time() < end:
            rl, _, _ = select.select([master], [], [], 0.05)
            if rl:
                try:
                    d = os.read(master, 65536)
                except OSError:
                    return
                if not d:
                    return
                out += d

    # wait for the first prompt (best effort; still proceed if it never shows)
    deadline = time.time() + 60
    while prompt not in out and time.time() < deadline:
        rl, _, _ = select.select([master], [], [], 0.2)
        if rl:
            try:
                d = os.read(master, 65536)
            except OSError:
                break
            if not d:
                break
            out += d

    for ln in lines:
        try:
            os.write(master, (ln + '\n').encode())
        except OSError:
            break

    rc = None
    deadline = time.time() + 90
    while time.time() < deadline:
        rl, _, _ = select.select([master], [], [], 0.2)
        if rl:
            try:
                d = os.read(master, 65536)
            except OSError:
                d = b''
            if d:
                out += d
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid:
            if os.WIFEXITED(status):
                rc = os.WEXITSTATUS(status)
            elif os.WIFSIGNALED(status):
                rc = -os.WTERMSIG(status)
            else:
                rc = 99
            break
    if rc is None:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
        rc = 124
    while True:
        rl, _, _ = select.select([master], [], [], 0.2)
        if not rl:
            break
        try:
            d = os.read(master, 65536)
        except OSError:
            break
        if not d:
            break
        out += d
    try:
        os.close(master)
    except OSError:
        pass
    return rc, out


def main():
    args = sys.argv[1:]
    on_disk = False
    if args and args[0] == '--on-disk':
        on_disk = True
        args = args[1:]
    elif args and args[0] == '--standalone':
        on_disk = False
        args = args[1:]
    else:
        # default: standalone (bootstrap-copy style)
        on_disk = False
    if '--' in args:
        idx = args.index('--')
        script = args[0]
        prompt = args[1]
        lines = args[2:idx]
        bash_args = args[idx + 1:]
    else:
        script = args[0]
        prompt = args[1]
        lines = args[2:]
        bash_args = []

    tmpdir = None
    if on_disk:
        script_path = script
    else:
        # standalone: copy to a temp dir with no valid tree next to it, so
        # detect_mode() resolves the bootstrap copy (BASH_SOURCE non-empty but
        # no installed layout around it).
        tmpdir = tempfile.mkdtemp(prefix='hd-pty-')
        script_path = os.path.join(tmpdir, 'setup.sh')
        with open(script_path, 'wb') as f:
            f.write(open(script, 'rb').read())
        os.chmod(script_path, 0o755)

    try:
        rc, out = run(script_path, prompt.encode(), lines, bash_args)
    finally:
        if tmpdir is not None:
            shutil.rmtree(tmpdir, ignore_errors=True)
    sys.stdout.write('%s\n' % rc)
    sys.stdout.flush()
    sys.stdout.write(out.decode('utf-8', 'replace'))
    sys.stdout.flush()
    return rc


if __name__ == '__main__':
    sys.exit(main())
