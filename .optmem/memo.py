#!/usr/bin/env python3
"""OptMem: a permanent, append-only memory for AI agents (Project-Scoped).

  {memo} init              create this memory; print the setup block.
  {memo} wake [part [T]]   read your memory. Run first, every session.
  {memo} note "..."        record one memory: one short line.
  {memo} nap [id "..."]    do the pending compressions.
  {memo} recall <regex>    search every memory ever recorded.
  {memo} zoom <lo>-<hi>    open a tree node: its two halves.
  {memo} forget <lo>-<hi>  drop a bad summary; nap rebuilds it.
  {memo} config [NAME=N]   show this memory's sizes, or change one.
  {memo} import <file>     bulk-load dated memories (bootstrap only).

Memories default to the project-local './memory' directory next to this script.
"""

import datetime
try:
    import fcntl
except ImportError:
    fcntl = None  # Windows fallback using msvcrt below
import os
import re
import sys
from collections import deque

# Ensure UTF-8 output streams across all platforms
for _s in (sys.stdout, sys.stderr):
    if hasattr(_s, "reconfigure"):
        _s.reconfigure(encoding="utf-8")


def pretty(p):
    """Formats paths cleanly: project-relative (.\path) if inside cwd, otherwise ~ or absolute."""
    p = os.path.abspath(p)
    try:
        rel = os.path.relpath(p, os.getcwd())
        if not rel.startswith("..") and not os.path.isabs(rel):
            return f".\\{rel}" if sys.platform.startswith("win") else f"./{rel}"
    except ValueError:
        pass
    home = os.path.expanduser("~")
    return "~" + p[len(home):] if p.startswith(home + os.sep) else p


def get_invocation():
    """Detects best execution command, prioritizing PowerShell wrappers."""
    cwd = os.getcwd()
    root_ps1 = os.path.join(cwd, "memo.ps1")
    root_cmd = os.path.join(cwd, "memo.cmd")
    script_dir = os.path.dirname(os.path.abspath(__file__))
    script_ps1 = os.path.join(script_dir, "memo.ps1")

    if os.path.exists(root_ps1):
        return ".\\memo.ps1"
    if os.path.exists(root_cmd):
        return ".\\memo.cmd"
    if os.path.exists(script_ps1):
        return pretty(script_ps1)

    script_pretty = pretty(__file__)
    if sys.platform.startswith("win"):
        return f'python "{script_pretty}"'
    return script_pretty


ME = get_invocation()

KNOBS = {
    "WAKE_LINES": (96, "the memory context: how many lines wake prints"),
    "ENTRY_CHARS": (280, "the longest one memory may be, in bytes"),
    "PART_CHARS": (20000, "output paging: largest part, in bytes"),
    "PART_LINES": (500, "output paging: largest part, in lines"),
}
WAKE_LINES = KNOBS["WAKE_LINES"][0]
ENTRY_CHARS = KNOBS["ENTRY_CHARS"][0]
PART_CHARS = KNOBS["PART_CHARS"][0]
PART_LINES = KNOBS["PART_LINES"][0]

RAW_MAX = 16
LOG_REC = 320
TREE_REC = 288


# ---------------------------------------------------------------- blocks

def _cover(T, alpha):
    root = 1
    while root < T:
        root *= 2
    out, stack = [], [(0, root)]
    while stack:
        lo, hi = stack.pop()
        if lo >= T:
            continue
        size = hi - lo
        if size > 1 and (hi > T or size > alpha * (T - lo)):
            mid = (lo + hi) // 2
            stack.append((mid, hi))
            stack.append((lo, mid))
        else:
            out.append((lo, hi))
    out.sort()
    return out


def cover(T, budget):
    if T <= 0:
        return []
    if T <= budget:
        return [(i, i + 1) for i in range(T)]
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if len(_cover(T, mid)) > budget:
            lo = mid
        else:
            hi = mid
    out = _cover(T, hi)
    while len(out) < budget:
        i = max((i for i, b in enumerate(out) if b[1] - b[0] > 1), default=None)
        if i is None:
            break
        lo_, hi_ = out[i]
        mid = (lo_ + hi_) // 2
        out[i:i + 1] = [(lo_, mid), (mid, hi_)]
    return out


# ---------------------------------------------------------------- store

def memory_dir():
    """Defaults to the 'memory' directory next to this script inside the project."""
    if "MEMORY_DIR" in os.environ:
        return os.path.expanduser(os.environ["MEMORY_DIR"])
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(script_dir, "memory")


def store():
    d = memory_dir()
    if not os.path.isdir(d):
        die("No memory store found at %s.\nTo initialize it in this project, run: %s init\n"
            "Or set MEMORY_DIR to point to an existing location." % (pretty(d), ME))
    os.makedirs(os.path.join(d, "TREE"), exist_ok=True)
    p = os.path.join(d, "LOG.txt")
    if not os.path.exists(p):
        open(p, "a").close()
    return d


def size(k, v, where=""):
    if not v.isdigit() or int(v) < 1:
        die("%s%s must be a positive whole number, not '%s'." % (where, k, v))
    top = min(TREE_REC - 8, LOG_REC - 40)
    if k == "ENTRY_CHARS" and int(v) > top:
        die("%sENTRY_CHARS is at most %d: a memory has to fit the fixed-width records." % (where, top))
    return int(v)


def overrides(d):
    out = {}
    p = os.path.join(d, "config")
    if not os.path.exists(p):
        return out
    for n, line in enumerate(open(p, encoding="utf-8"), 1):
        line = line.split("#")[0].strip()
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip().upper(), v.strip()
        where = "%s line %d: " % (pretty(p), n)
        if k not in KNOBS:
            die("%s%s is not a size. Delete the line, or name one of: %s."
                % (where, k, ", ".join(KNOBS)))
        out[k] = size(k, v, where)
    return out


def config(d):
    for k, v in overrides(d).items():
        globals()[k] = v


def write_config(d, over):
    out = ["# OptMem sizes for this project memory.",
           "# Edit with `%s config NAME=VALUE`." % ME, ""]
    for k, (default, what) in KNOBS.items():
        out.append("%-2s%-12s = %-6d # %s"
                   % ("" if k in over else "# ", k, over.get(k, default), what))
    with open(os.path.join(d, "config"), "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


def log_path(d):
    return os.path.join(d, "LOG.txt")


def tree_path(d, size):
    return os.path.join(d, "TREE", str(size))


def count(path, rec):
    try:
        return os.path.getsize(path) // rec
    except FileNotFoundError:
        return 0


def log_len(d):
    return count(log_path(d), LOG_REC)


def repair(path, rec):
    try:
        n = os.path.getsize(path)
    except FileNotFoundError:
        return
    if n % rec:
        with open(path, "r+b") as f:
            f.truncate(n - n % rec)


def parse(line):
    head, _, rest = line.partition(" ")
    date, _, text = rest.partition(" ")
    return int(head[1:]), date, text


def records(buf):
    return [parse(buf[i * LOG_REC:(i + 1) * LOG_REC].decode().rstrip())
            for i in range(len(buf) // LOG_REC)]


def log_slice(d, lo, hi):
    with open(log_path(d), "rb") as f:
        f.seek(lo * LOG_REC)
        return records(f.read((hi - lo) * LOG_REC))


def log_get(d, i):
    return log_slice(d, i, i + 1)[0]


def log_scan(d):
    with open(log_path(d), "rb") as f:
        while True:
            buf = f.read(LOG_REC * 4096)
            if not buf:
                return
            for e in records(buf):
                yield e


def tree_get(d, lo, hi):
    size = hi - lo
    try:
        with open(tree_path(d, size), "rb") as f:
            f.seek((lo // size) * TREE_REC)
            rec = f.read(TREE_REC)
    except FileNotFoundError:
        return None
    try:
        return rec.decode().rstrip() or None
    except UnicodeDecodeError:
        die("The summary of #%d-%d is corrupt. Run: %s forget %d-%d"
            % (lo, hi - 1, ME, lo, hi - 1))


def pad(text, rec):
    b = text.encode()
    if len(b) > rec - 1:
        die("Too long: %d bytes. The record holds %d." % (len(b), rec - 1))
    return b + b" " * (rec - 1 - len(b)) + b"\n"


def locked(d):
    lock = open(os.path.join(d, ".lock"), "a")
    if fcntl is not None:
        fcntl.flock(lock, fcntl.LOCK_EX)
    else:
        import msvcrt as _ms
        import time as _t
        waited = 0.0
        while True:
            try:
                _ms.locking(lock.fileno(), _ms.LK_NBLCK, 1)
                break
            except OSError:
                if waited > 30.0:
                    raise
                _t.sleep(min(0.01 + waited * 0.2, 0.25))
                waited += 0.01
        _orig_close = lock.close
        def _close():
            try:
                _ms.locking(lock.fileno(), _ms.LK_UNLCK, 1)
            except Exception:
                pass
            _orig_close()
        lock.close = _close
    return lock


def log_append(d, items):
    lock = locked(d)
    try:
        repair(log_path(d), LOG_REC)
        base = log_len(d)
        with open(log_path(d), "ab") as f:
            for k, (date, text) in enumerate(items):
                f.write(pad("#%d %s %s" % (base + k, date, text), LOG_REC))
            f.flush()
            os.fsync(f.fileno())
        return base
    finally:
        lock.close()


def tree_put(d, lo, hi, text):
    size = hi - lo
    lock = locked(d)
    try:
        p = tree_path(d, size)
        repair(p, TREE_REC)
        if count(p, TREE_REC) != lo // size:
            return False
        with open(p, "ab") as f:
            f.write(pad(text, TREE_REC))
            f.flush()
            os.fsync(f.fileno())
        return True
    finally:
        lock.close()


def tree_drop(d, lo, hi):
    gone, size = [], hi - lo
    lock = locked(d)
    try:
        while size <= log_len(d):
            p, k = tree_path(d, size), lo // size
            n = count(p, TREE_REC)
            if n > k:
                gone += [(i * size, (i + 1) * size) for i in range(k, n)]
                with open(p, "r+b") as f:
                    f.truncate(k * TREE_REC)
            size *= 2
        return gone
    finally:
        lock.close()


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def plural(n, word):
    if n == 1:
        return "1 " + word
    if word.endswith("y"):
        word = word[:-1] + "ie"
    elif word.endswith(("s", "h", "x")):
        word += "e"
    return "%d %ss" % (n, word)


def block_id(s):
    m = re.fullmatch(r"(\d+)-(\d+)", s)
    if not m:
        die("'%s' is not a block id. Copy it from the prompt." % s)
    lo, hi = int(m.group(1)), int(m.group(2)) + 1
    n = hi - lo
    if n < 2 or n & (n - 1) or lo % n:
        die("%s is not a block. Copy the id printed by wake, like 16-31." % s)
    return lo, hi


def check(text):
    text = text.strip()
    if not text:
        die("Empty. A memory is one line of text.")
    if "\n" in text or "\r" in text:
        die("%d lines. A memory is one line: merge them, or note them separately." % (text.count("\n") + 1))
    n = len(text.encode())
    if n > ENTRY_CHARS:
        die("Too long: %d bytes, limit %d. Accented characters cost 2 bytes. Compress it further." % (n, ENTRY_CHARS))
    return text


# ---------------------------------------------------------------- naps

def pending(d, T, limit=None):
    todo, size = [], 2
    while size <= T:
        have = count(tree_path(d, size), TREE_REC)
        for k in range(have, T // size):
            todo.append((k * size, (k + 1) * size))
            if limit and len(todo) >= limit:
                return todo
        size *= 2
    return todo


def pending_count(d, T):
    n, size = 0, 2
    while size <= T:
        n += max(0, T // size - count(tree_path(d, size), TREE_REC))
        size *= 2
    return n


def nap_prompt(d, lo, hi, left):
    if hi - lo <= RAW_MAX:
        body = "\n".join("  #%d %s %s" % e for e in log_slice(d, lo, hi))
    else:
        mid, halves = (lo + hi) // 2, []
        for a, b in ((lo, mid), (mid, hi)):
            s = tree_get(d, a, b)
            if s is None:
                die("The summary of #%d-%d is blank. Run: %s forget %d-%d"
                    % (a, b - 1, ME, a, b - 1))
            halves.append("  #%d-%d %s" % (a, b - 1, s))
        body = "\n".join(halves)
    tail = "" if not left else "\n%s after this one." % (
        "1 compression remains" if left == 1 else
        "%d compressions remain" % left)
    return ("Compress memories #%d-%d into one line of at most %d bytes.\n"
            "Keep what has lasting effect, drop what does not. Invent nothing.\n\n"
            "%s\n%s\n"
            "Run: %s nap %d-%d \"<your line>\""
            % (lo, hi - 1, ENTRY_CHARS, body, tail, ME, lo, hi - 1))


def next_nap(d, T):
    todo = pending(d, T, limit=1)
    if not todo:
        return None
    lo, hi = todo[0]
    return nap_prompt(d, lo, hi, pending_count(d, T) - 1)


# ---------------------------------------------------------------- commands

TEMPLATE = """\
## Memory (Project-Scoped)

Your memory is OptMem:
- Tool: `{memo}`
- Storage: `{data}`

OptMem outlives every session, compaction, model and vendor change.
Without it you do not know who you are, or what was decided and tried.

### At startup: activating OptMem (mandatory)

Run `{memo} wake` before any other tool call, in every session, and
then do exactly what it prints, to the end of its output.

### While working: register memories (mandatory)

Call `{memo} note "<1 line, max {chars} bytes>"` whenever you learn
something new, or something worth keeping happens in this project.
Do not register redundant memories.
If `{memo} note` asks a compression: do it before your next action.
Never edit or delete anything under `{data}`: the tool manages it.

### When you need an old memory: search, or navigate

`{memo} recall <regex>` searches every memory in this project.
`{memo} zoom <a-b>` opens a tree node into its two halves.

### If you're a subagent: skip everything above

Parallel sessions in this workspace may write memories. A subagent must not:
write `You are a subagent. Don't run memo.` when spawning one.
"""


def cmd_init(d, args):
    if args:
        die("usage: %s init" % ME)
    fresh = not os.path.isdir(d)
    os.makedirs(os.path.join(d, "TREE"), exist_ok=True)
    open(log_path(d), "a").close()
    if not os.path.exists(os.path.join(d, "config")):
        write_config(d, {})
    config(d)
    if fresh:
        print("Created %s: local project memory initialized." % pretty(d))
    else:
        print("Found %s: %s." % (pretty(d), plural(log_len(d), "memory")))
    print("Configuration: %s\\config" % pretty(d))
    print()
    print("Paste this into your project's AGENTS.md:")
    print()
    print(TEMPLATE.format(memo=ME, data=pretty(d), chars=ENTRY_CHARS).rstrip())


def paginate(lines):
    parts, cur, size = [], [], 0
    for line in lines:
        n = len(line.encode()) + 1
        if cur and (len(cur) >= PART_LINES or size + n > PART_CHARS):
            parts.append(cur)
            cur, size = [], 0
        cur.append(line)
        size += n
    if cur:
        parts.append(cur)
    return parts


def cmd_wake(d, args):
    now = log_len(d)
    k, T = 1, now
    if args:
        if len(args) > 2 or not all(a.isdigit() for a in args):
            die("usage: %s wake [part [T]]" % ME)
        k = int(args[0])
        if len(args) == 2:
            T = int(args[1])
            if T > now:
                die("T=%d, but the log holds %s. Run: %s wake"
                    % (T, plural(now, "memory"), ME))
    if not T:
        print("No project memories yet. Record the first with: %s note \"<one line>\"" % ME)
        print("You are awake.")
        return
    lines = []
    for lo, hi in cover(T, WAKE_LINES):
        if hi - lo == 1:
            lines.append("#%d %s %s" % log_get(d, lo))
        else:
            s = tree_get(d, lo, hi)
            if s is None:
                nap = next_nap(d, T)
                if nap:
                    print("Cannot wake: the memory context needs #%d-%d, which is not compressed yet.\n"
                          "Do the %s below, then run %s wake again.\n"
                          % (lo, hi - 1, plural(pending_count(d, T), "compression"), ME))
                    print(nap)
                    sys.exit(1)
                s = tree_get(d, lo, hi)
            if s is None:
                die("The summary of #%d-%d is blank. Run: %s forget %d-%d" % (lo, hi - 1, ME, lo, hi - 1))
            lines.append("#%d-%d %s" % (lo, hi - 1, s))
    parts = paginate(lines)
    if not 1 <= k <= len(parts):
        die("No part %d: the memory has %s. Run: %s wake" % (k, plural(len(parts), "part"), ME))
    if len(parts) > 1:
        print("Your memory, part %d of %d, oldest first (%s)." % (k, len(parts), plural(T, "memory")))
    print("\n".join(parts[k - 1]))
    if k < len(parts):
        print("Not awake yet. Run: %s wake %d %d" % (ME, k + 1, T))
    else:
        print("You are awake.")
        nap = next_nap(d, T)
        if nap:
            print("\n" + nap)


def cmd_note(d, args):
    if len(args) != 1:
        die("usage: %s note \"<one line, at most %d bytes>\"" % (ME, ENTRY_CHARS))
    text = check(args[0])
    i = log_append(d, [(datetime.date.today().isoformat(), text)])
    print("Saved as #%d." % i)
    nap = next_nap(d, i + 1)
    if nap:
        print("\n" + nap)


def cmd_nap(d, args):
    T, said = log_len(d), False
    if args:
        said = True
        if len(args) != 2:
            die("usage: %s nap <lo>-<hi> \"<one line>\"" % ME)
        lo, hi = block_id(args[0])
        todo = pending(d, T, limit=1)
        if not todo:
            print("Nothing left to compress.")
            return
        if (lo, hi) != todo[0]:
            if tree_get(d, lo, hi) is not None:
                print("%d-%d is already settled." % (lo, hi - 1))
            else:
                die("Wrong block: %s. Blocks are built in order; the next is %d-%d. Run: %s nap"
                    % (args[0], todo[0][0], todo[0][1] - 1, ME))
        elif not tree_put(d, lo, hi, check(args[1])):
            print("%d-%d was settled or forgotten meanwhile." % (lo, hi - 1))
        else:
            print("%d-%d saved." % (lo, hi - 1))
    nap = next_nap(d, T)
    if not nap:
        print("Nothing left to compress.")
        return
    print(("\n" if said else "") + nap)


def cmd_config(d, args):
    over = overrides(d)
    for a in args:
        k, eq, v = a.partition("=")
        k = k.strip().upper()
        if not eq or k not in KNOBS:
            die("usage: %s config [NAME=VALUE ...]   # NAME one of %s" % (ME, ", ".join(KNOBS)))
        if v.strip():
            over[k] = size(k, v.strip())
        else:
            over.pop(k, None)
    if args:
        write_config(d, over)
    for k, (default, what) in KNOBS.items():
        print("%-12s %-7d %s%s" % (k, over.get(k, default), what,
                                   "" if k not in over else " (default %d)" % default))


def cmd_forget(d, args):
    if len(args) != 1:
        die("usage: %s forget <lo>-<hi>" % ME)
    gone = tree_drop(d, *block_id(args[0]))
    if not gone:
        die("No summary at %s." % args[0])
    print("Forgot %s, from %d-%d up. Run: %s nap"
          % (plural(len(gone), "summary"), gone[0][0], gone[0][1] - 1, ME))


def cmd_recall(d, args):
    if len(args) != 1:
        die("usage: %s recall <regex>" % ME)
    try:
        pat = re.compile(args[0], re.I)
    except re.error as e:
        die("bad regex: %s" % e)
    hits, out, size = 0, deque(), 0
    for e in log_scan(d):
        line = "#%d %s %s" % e
        if not pat.search(line):
            continue
        hits += 1
        out.append(line)
        size += len(line.encode()) + 1
        while size > PART_CHARS:
            size -= len(out.popleft().encode()) + 1
    if not hits:
        print("No match.")
        return
    print("\n".join(out))
    if len(out) < hits:
        print("Newest %d of %s. Narrow the regex." % (len(out), plural(hits, "match")))
    else:
        print("%s." % plural(hits, "match"))


def cmd_zoom(d, args):
    if len(args) != 1:
        die("usage: %s zoom <lo>-<hi>   # a block id, as wake prints them" % ME)
    lo, hi = block_id(args[0])
    T = log_len(d)
    if lo >= T:
        die("#%s is beyond the memory: it holds %s. Run: %s wake" % (args[0], plural(T, "memory"), ME))
    mid = (lo + hi) // 2
    for a, b in ((lo, mid), (mid, hi)):
        if a >= T:
            continue
        if b - a == 1:
            print("#%d %s %s" % log_get(d, a))
        else:
            print("#%d-%d %s" % (a, b - 1, tree_get(d, a, b) or "not compressed yet"))


def cmd_import(d, args):
    if len(args) != 1:
        die("usage: %s import <file>   # lines of 'YYYY-MM-DD <text>'" % ME)
    try:
        src = open(args[0], encoding="utf-8").readlines()
    except UnicodeDecodeError:
        die("%s is not UTF-8 text. Convert it, then import again." % pretty(args[0]))
    last = log_get(d, log_len(d) - 1)[1] if log_len(d) else "0000-00-00"
    out = []
    for i, line in enumerate(src, 1):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        date, _, text = line.partition(" ")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            die("line %d: expected 'YYYY-MM-DD <text>', got: %s" % (i, line))
        try:
            datetime.datetime.strptime(date, "%Y-%m-%d")
        except ValueError:
            die("line %d: %s is not a real date." % (i, date))
        if date < last:
            die("line %d: date %s precedes the previous memory (%s)." % (i, date, last))
        text = text.strip()
        if not text or len(text.encode()) > ENTRY_CHARS:
            die("line %d: %d bytes, limit %d." % (i, len(text.encode()), ENTRY_CHARS))
        out.append((date, text))
        last = date
    if not out:
        die("%s has no memories." % args[0])
    base = log_append(d, out)
    print("Imported %s, #%d to #%d." % (plural(len(out), "memory"), base, base + len(out) - 1))
    n = pending_count(d, log_len(d))
    if n:
        print("%s pending. Run: %s nap" % (plural(n, "compression"), ME))


COMMANDS = {"init": cmd_init, "wake": cmd_wake, "note": cmd_note,
            "nap": cmd_nap, "recall": cmd_recall, "zoom": cmd_zoom,
            "forget": cmd_forget, "config": cmd_config, "import": cmd_import}


def main():
    usage = __doc__.strip().format(memo=ME)
    if len(sys.argv) < 2:
        print(usage)
        sys.exit(0)
    cmd = sys.argv[1]
    if cmd not in COMMANDS:
        print("No such command: %s\n" % cmd, file=sys.stderr)
        print(usage, file=sys.stderr)
        sys.exit(1)
    try:
        if cmd == "init":
            cmd_init(memory_dir(), sys.argv[2:])
            return
        d = store()
        config(d)
        COMMANDS[cmd](d, sys.argv[2:])
    except OSError as e:
        die("%s: %s." % (pretty(e.filename or memory_dir()), e.strerror or e))


if __name__ == "__main__":
    main()