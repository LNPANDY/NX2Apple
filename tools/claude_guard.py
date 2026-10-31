#!/usr/bin/env python3
"""Claude Code PreToolUse hook for the Bash tool (.claude/settings.json). Reads the call as JSON on stdin and exits 2, with the reason
on stderr, for a `git push` to main or master and for `--no-verify` on `git commit` and `git push`. Exit 0 lets the call go on."""
import json
import os
import re
import shlex
import subprocess
import sys

PROTECTED = ('main', 'master')
WRAPPERS = ('sudo', 'env', 'command', 'time', 'nohup', 'exec')
PUSH_ARG_FLAGS = ('-o', '--push-option', '--receive-pack', '--exec', '--repo')   # options that take the next word as their value
GIT_ARG_FLAGS = ('-C', '-c', '--git-dir', '--work-tree', '--namespace')
SHELLS = ('sh', 'bash', 'zsh')

NO_PR = 'Patches and code go through a PR: push a branch and open a pull request. Nothing is pushed to main or master directly.'
NO_VERIFY = 'The pre-commit and pre-push hooks stay on. Fix what they report instead of using --no-verify.'


def segments(command):
    """The commands in a shell line as word lists, split at ; && || | & and newlines. None when the line does not parse."""
    lex = shlex.shlex(command, posix=True, punctuation_chars=';&|()\n')
    lex.whitespace_split, lex.whitespace = True, ' \t\r'
    try:
        words = list(lex)
    except ValueError:
        return None
    out, cur = [], []
    for w in words:
        if w and set(w) <= set(';&|()\n'):
            if cur: out.append(cur)
            cur = []
        else:
            cur.append(w)
    return out + ([cur] if cur else [])


def git_call(words):
    """(global options, subcommand, its arguments) for a segment that runs git, else None."""
    i = 0
    while i < len(words) and (words[i] in WRAPPERS or re.fullmatch(r'\w+=.*', words[i])): i += 1
    if i >= len(words) or os.path.basename(words[i]) != 'git': return None
    i += 1
    opts = []
    while i < len(words) and words[i].startswith('-'):
        opts.append(words[i])
        if words[i] in GIT_ARG_FLAGS and i + 1 < len(words):
            i += 1
            opts.append(words[i])
        i += 1
    return (opts, words[i], words[i + 1:]) if i < len(words) else None


def current_branch(cwd, opts):
    if '-C' in opts: cwd = os.path.join(cwd, opts[opts.index('-C') + 1])
    r = subprocess.run(['git', 'branch', '--show-current'], cwd=cwd, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ''


def pushes_to_protected(opts, args, cwd):
    flags = [a for a in args if a.startswith('-')]
    if '--all' in flags or '--mirror' in flags: return True
    pos, skip = [], False
    for a in args:
        if skip: skip = False
        elif a in PUSH_ARG_FLAGS: skip = True
        elif not a.startswith('-'): pos.append(a)
    refspecs = pos[1:]   # the first word is the remote
    if not refspecs: return current_branch(cwd, opts) in PROTECTED
    for r in refspecs:
        dest = r.lstrip('+').split(':')[-1]
        if dest == 'HEAD': dest = current_branch(cwd, opts)
        if dest.removeprefix('refs/heads/') in PROTECTED: return True
    return False


def verdict(command, cwd='.'):
    """The reason to stop this command, or None."""
    segs = segments(command)
    if segs is None:   # unbalanced quotes: look at the raw text
        if re.search(r'\bgit\b.*\bpush\b.*\b(main|master)\b', command): return NO_PR
        return NO_VERIFY if re.search(r'\bgit\b.*\b(commit|push)\b.*--no-verify', command) else None
    for words in segs:
        if os.path.basename(words[0]) in SHELLS and '-c' in words and words.index('-c') + 1 < len(words):
            reason = verdict(words[words.index('-c') + 1], cwd)   # bash -c "git push origin main"
            if reason: return reason
        call = git_call(words)
        if not call: continue
        opts, sub, args = call
        if sub == 'push' and pushes_to_protected(opts, args, cwd): return NO_PR
        if sub in ('push', 'commit') and ('--no-verify' in args or (sub == 'commit' and any(re.fullmatch(r'-[a-zA-Z]*n[a-zA-Z]*', a) for a in args))):
            return NO_VERIFY
    return None


def main():
    try:
        call = json.load(sys.stdin)
        command = call['tool_input']['command']
    except (ValueError, KeyError, TypeError):
        return 0   # not a call this guard understands: no decision
    reason = verdict(command, call.get('cwd') or os.getcwd())
    if reason:
        print(f'Blocked by tools/claude_guard.py: {reason}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
