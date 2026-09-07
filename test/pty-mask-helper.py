#!/usr/bin/env python3
"""pty-mask-helper.py - raw-mode pty harness for the Phase C masked API-key
read in scripts/setup.sh.

setup.sh reads keys through a raw-mode masked_read() loop (stty -icanon -isig
-echo min 1 time 0; per-character '*' feedback to stderr; the value is
returned through a 600-mode mktemp temp file, never stdout). The key MUST be
typed only while raw mode is active - any bytes written while the line
discipline is still canonical get ECHOed at write time and would leak the key
into the captured transcript. pty-helper.py (unmodified) writes every answer
line up-front for canonical reads; this helper instead:

  1. waits for the first prompt substring, then writes the NON-secret preamble
     answer lines up-front (consumed canonically before the key prompt),
  2. per STAGE: waits for the stage prompt substring, then polls the pty
     MASTER termios until the slave is in raw mode (ICANON off - Python's
     tcgetattr() on the master reflects the slave's lflags), then writes the
     stage payload bytes in ONE write (the raw line discipline passes every
     byte through; setup.sh's `dd bs=1 count=1` loop consumes them serially),
  3. reports the child exit code, a per-stage net-star count (mask '*' minus
     backspace erases, proving per-character feedback happened and the no-echo
     fallback did NOT silently kick in), and a terminal-restore probe read
     from tcgetattr(master) after the child exits.

--canon SUBSTR LINE writes a non-secret canonical line (newline-terminated)
after SUBSTR appears, WITHOUT waiting for raw mode - used for the trailing
port answers, which the masked dd loop must never consume as key bytes. If raw
mode is never observed for a --stage (setup.sh fell back to `read -s` because
stty failed - Phase C C5), the payload is written as ONE canonical line
(consumed by read -s) and later masked stages fall back to immediate canonical
writes so the harness cannot hang.

The secret itself never crosses stdout (temp-file return), so the transcript
(and an optional --child-stdout log) never contain it; the per-char stars go
to stderr only, so a redirected stdout log stays clean of mask feedback.

Usage:
  pty-mask-helper.py [--on-disk|--standalone] SCRIPT FIRST_PROMPT PRE_LINE...
    --stage PROMPT_SUBSTR PAYLOAD_BYTES [--stage ...]...
    [--canon PROMPT_SUBSTR LINE]...
    [--child-stdout LOGFILE] [--no-submit] [--raw-timeout SEC]
    [--prompt-timeout SEC] [-- ARGS...]

  SCRIPT           setup.sh path (on-disk: inside the tree; standalone: copied
                   to a temp dir like pty-helper.py)
  FIRST_PROMPT     substring waited for before writing the PRE_LINEs
  PRE_LINE...      non-secret answer lines (project/ns/user/provider/model),
                   written up-front and consumed canonically
  --stage SUBSTR BYTES   type BYTES while raw after SUBSTR appears; repeatable.
                   PAYLOAD_BYTES is a latin-1 character string (use bash $'...'
                   for control bytes such as $'\\x7f' backspace / $'\\x03' ^C).
                   A trailing newline is appended to submit unless --no-submit.
  --canon SUBSTR LINE   write LINE (newline-terminated) after SUBSTR appears,
                   WITHOUT waiting for raw mode - for non-secret trailing
                   answers (e.g. ports) that the masked loop must not consume.
  --child-stdout F     child fd 1 goes to F (a plain log), not the pty - used
                   to prove a redirected stdout log never sees the key or the
                   per-char '*' feedback (C4). stderr/stdin still use the pty.
  --no-submit      do not append a trailing newline to the LAST stage payload
                   (for the ^C path: type "ab\\x03" and stop - C1).
  --raw-timeout N  seconds to wait for raw mode per stage (default 3).
  --prompt-timeout N  per-stage prompt wait once fallback (default 15).

Output on stdout:
  <child exit code>
  STARS_1=<net>        (per-stage net '*' count; or STARS_i for each --stage)
  RESTORED=yes|no      (terminal back to canonical after the child exits)
  <transcript>         (everything captured from the pty)
"""
import os, pty, sys, time, select, signal, tempfile, shutil, termios, fcntl


class Child:
    """Reap-guard: the first successful waitpid() stores the raw wait status so
    every later caller sees the same rc instead of a spurious ChildProcessError
    (which previously made the helper report a false 124 timeout after the child
    had actually already exited and been reaped inside drain()/wait_prompt())."""

    def __init__(self, pid):
        self.pid = pid
        self.status = None  # raw os.waitpid status once the child is reaped

    def reap(self):
        """Reap if done; return True once the exit status is known."""
        if self.status is not None:
            return True
        try:
            wpid, st = os.waitpid(self.pid, os.WNOHANG)
        except OSError:
            self.status = 0
            return True
        if wpid:
            self.status = st
            return True
        return False

    def done(self):
        return self.status is not None

    def rc(self):
        """Decode to an exit code (or negative signal number)."""
        if os.WIFEXITED(self.status):
            return os.WEXITSTATUS(self.status)
        if os.WIFSIGNALED(self.status):
            return -os.WTERMSIG(self.status)
        return 99


def drain(out, master, child, seconds, stop_on=None):
    """Read from master into out (a bytearray) for up to `seconds`. Returns 0
    on timeout, 1 when the child has already exited (recorded in `child`), or 2
    when `stop_on` (a bytes needle) appeared anywhere in out."""
    if stop_on is not None and stop_on in out:
        return 2
    end = time.time() + seconds
    while time.time() < end:
        rl, _, _ = select.select([master], [], [], 0.05)
        if rl:
            try:
                d = os.read(master, 65536)
            except OSError:
                d = b''
            if d:
                out += d
                if stop_on is not None and stop_on in out:
                    return 2
        if child.reap():
            return 1
    return 0


def wait_prompt(out, needle, start, master, child, deadline):
    """Wait until `needle` appears at-or-after `start` in `out`, capturing any
    bytes the child produces meanwhile. Searches only the not-yet-consumed
    region so consecutive identical prompts (a retried key) are each matched
    in turn. Returns the START index of the match, or -1 on timeout / exit
    (exit recorded in `child`)."""
    pos = bytes(out).find(needle, start)
    while pos < 0 and time.time() < deadline:
        rl, _, _ = select.select([master], [], [], 0.2)
        if rl:
            try:
                d = os.read(master, 65536)
            except OSError:
                return -1
            if not d:
                return -1
            out += d
        if child.reap():
            return -1
        pos = bytes(out).find(needle, start)
    return pos if pos >= 0 else -1


def in_raw(master):
    """True when the pty slave is in raw mode (ICANON off)."""
    try:
        lf = termios.tcgetattr(master)[3]
        return (lf & termios.ICANON) == 0
    except OSError:
        return False


def net_stars(blob):
    """net '*' feedback = literal '*' minus backspace erases ('\\b \\b' = two 0x08)."""
    stars = blob.count(b'*')
    backspaces = blob.count(b'\x08') // 2
    return stars - backspaces


def run(script_path, first_prompt, pre_lines, stages, bash_args,
        child_stdout=None, no_submit=False, raw_timeout=3.0,
        prompt_timeout=15.0):
    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0)
        if child_stdout is None:
            os.dup2(slave, 1)
        else:
            fd = os.open(child_stdout, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.dup2(fd, 1)
            os.close(fd)
        os.dup2(slave, 2)
        os.close(master)
        os.close(slave)
        os.execvp('bash', ['bash', script_path] + bash_args)
    os.close(slave)

    out = bytearray()
    child = Child(pid)
    # wait for the first prompt, then write the preamble (canonical-consumed)
    drain(out, master, child, 60, first_prompt.encode())
    for ln in pre_lines:
        try:
            os.write(master, (ln + '\n').encode())
        except OSError:
            break

    star_reports = []
    # `wait_from` is the START of the not-yet-consumed region we search for the
    # NEXT stage's prompt. It is set to the POSITION of the prompt we matched
    # (not len(out)) so repeated identical prompts (a retried key after a
    # mismatch) are each matched in turn: find(needle, endpos) re-finds the
    # same needle at endpos, and any LATER occurrence is found too.
    wait_from = len(out)  # the first masked prompt appears after pre-lines
    fallback = False
    for idx, (needle, payload, canon) in enumerate(stages):
        needle_b = needle.encode()
        if child.done():
            star_reports.append(0)
            break
        if canon:
            # non-secret trailing answer (e.g. ports): wait for ITS prompt,
            # then write one full canonical line. Never blind-write if the
            # prompt never appears - the masked dd loop would eat the bytes.
            start = len(out)
            p = wait_prompt(out, needle_b, wait_from, master, child,
                            time.time() + prompt_timeout)
            if p < 0 or child.done():
                star_reports.append(0)
                break
            try:
                os.write(master, (payload + '\n').encode('latin-1'))
            except OSError:
                pass
            star_reports.append(0)
            # drain until the NEXT stage's needle appears (the answer-echo then
            # the following prompt) and hand that needle's position forward -
            # otherwise the next canon stage would skip past its own prompt
            nxt = stages[idx + 1][0].encode() if idx + 1 < len(stages) else None
            if nxt is not None:
                p2 = wait_prompt(out, nxt, start, master, child,
                                 time.time() + 8)
                wait_from = p2 if p2 >= 0 else len(out)
            else:
                drain(out, master, child, 2)
                wait_from = len(out)
            continue
        if fallback:
            # under a read -s fallback, masked-read prompts never render and
            # there is NO confirmation stage; skip any remaining masked stage
            # silently (nothing to write, nothing to wait for)
            star_reports.append(0)
            wait_from = len(out)
            continue

        # masked stage: wait for this stage's prompt to appear
        p = wait_prompt(out, needle_b, wait_from, master, child,
                        time.time() + 60)
        if p < 0 or child.done():
            # prompt never appeared (child likely died / flow diverged):
            # stop driving stages rather than polluting a waiting masked_read
            star_reports.append(0)
            break

        # wait for raw mode: typing must happen only while raw to avoid echo,
        # which would leak the key into the captured transcript
        raw_seen = False
        raw_deadline = time.time() + raw_timeout
        while time.time() < raw_deadline and not raw_seen:
            if child.reap():
                break
            raw_seen = in_raw(master)
            if not raw_seen:
                time.sleep(0.02)
        start = len(out)
        data = payload
        if not (no_submit and idx == len(stages) - 1):
            data += '\n'
        try:
            os.write(master, data.encode('latin-1'))
        except OSError:
            pass
        if not raw_seen:
            # setup.sh fell back to `read -s` (stty failed): the canonical
            # line we just wrote was consumed by it; no confirmation follows
            star_reports.append(0)
            fallback = True
            wait_from = len(out)
            continue

        # drain until the NEXT stage's prompt appears (or the child exits),
        # then count THIS stage's stars (mask '*' minus backspace erases)
        nxt = stages[idx + 1][0].encode() if idx + 1 < len(stages) else None
        if nxt is not None:
            p2 = wait_prompt(out, nxt, start, master, child, time.time() + 8)
            endpos = p2 if p2 >= 0 else len(out)
            star_slice = bytes(out[start:endpos])
        else:
            # last stage: drain everything the child emits BEFORE slicing,
            # else the star count for the final masked read is empty
            drain(out, master, child, 8)
            endpos = len(out)
            star_slice = bytes(out[start:endpos])
        star_reports.append(net_stars(star_slice))
        wait_from = endpos

    deadline = time.time() + 90
    while not child.done() and time.time() < deadline:
        rl, _, _ = select.select([master], [], [], 0.2)
        if rl:
            try:
                d = os.read(master, 65536)
            except OSError:
                d = b''
            if d:
                out += d
        child.reap()
    if not child.done():
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass
        rc = 124
    else:
        rc = child.rc()
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
    restored = 'yes' if in_raw(master) is False else 'no'
    try:
        os.close(master)
    except OSError:
        pass
    return rc, star_reports, restored, bytes(out)


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
        on_disk = False

    child_stdout = None
    no_submit = False
    raw_timeout = 3.0
    prompt_timeout = 15.0
    stages = []
    script = args[0]
    first_prompt = args[1]
    pre_lines = []
    bash_args = []
    i = 2
    while i < len(args):
        a = args[i]
        if a == '--stage':
            needle = args[i + 1]
            payload = args[i + 2]
            stages.append((needle, payload, False))
            i += 3
        elif a == '--canon':
            needle = args[i + 1]
            payload = args[i + 2]
            stages.append((needle, payload, True))
            i += 3
        elif a == '--child-stdout':
            child_stdout = args[i + 1]
            i += 2
        elif a == '--no-submit':
            no_submit = True
            i += 1
        elif a == '--raw-timeout':
            raw_timeout = float(args[i + 1])
            i += 2
        elif a == '--prompt-timeout':
            prompt_timeout = float(args[i + 1])
            i += 2
        elif a == '--':
            bash_args = args[i + 1:]
            break
        else:
            pre_lines.append(a)
            i += 1

    tmpdir = None
    if on_disk:
        script_path = script
    else:
        tmpdir = tempfile.mkdtemp(prefix='hd-maskpty-')
        script_path = os.path.join(tmpdir, 'setup.sh')
        with open(script_path, 'wb') as f:
            f.write(open(script, 'rb').read())
        os.chmod(script_path, 0o755)
    try:
        rc, star_reports, restored, out = run(
            script_path, first_prompt, pre_lines, stages, bash_args,
            child_stdout=child_stdout, no_submit=no_submit,
            raw_timeout=raw_timeout, prompt_timeout=prompt_timeout)
    finally:
        if tmpdir is not None:
            shutil.rmtree(tmpdir, ignore_errors=True)
    sys.stdout.write('%s\n' % rc)
    for idx, s in enumerate(star_reports, start=1):
        sys.stdout.write('STARS_%d=%s\n' % (idx, s))
    sys.stdout.write('RESTORED=%s\n' % restored)
    sys.stdout.flush()
    sys.stdout.write(out.decode('utf-8', 'replace'))
    sys.stdout.flush()
    return rc


if __name__ == '__main__':
    sys.exit(main())
