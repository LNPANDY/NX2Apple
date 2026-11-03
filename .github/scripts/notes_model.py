"""Run the Copilot CLI for the release notes with the first model id the account accepts.

The CLI does not list its models and has no alias for "the newest Sonnet": an id the account does not offer fails with
`Error: Model "<id>" from --model flag is not available.` (copilot 1.0.105). So the ids come in an ordered list, newest first, and only that
error moves on to the next one. Any other failure stops the chain. A Haiku id and `auto` are never used.

  notes_model.py --prompt FILE --out ANSWER [--candidates "ID ID ..."] [--override ID]
  --override (the repository variable RELEASE_NOTES_MODEL) replaces the list: that id alone, no fallback.
Writes the answer to ANSWER and the id used to <ANSWER dir>/model.txt, sets `ran` and `model` in $GITHUB_OUTPUT. Exit 1 when no model answered.
"""
import argparse
import os
import re
import subprocess
import sys

MODEL_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
NOT_AVAILABLE = re.compile(r'Model "[^"\n]*" from --model flag is not available\.')
TIMEOUT = 600
COPILOT_ARGS = ['--silent', '--no-ask-user', '--no-custom-instructions', '--no-auto-update', '--disable-builtin-mcps', '--disable-client-telemetry',
                '--available-tools=view', '--allow-all-tools', '--deny-tool=shell', '--deny-tool=write', '--deny-tool=url',
                '--secret-env-vars=COPILOT_GITHUB_TOKEN']


class ChainError(Exception):
    pass


def check_candidates(ids, override=False):
    """The ids, validated. The list never holds a Haiku or `auto`. A set override is only validated like TRIAGE_MODEL."""
    if not ids:
        raise ChainError('no model id to try')
    for i in ids:
        if not MODEL_ID.match(i):
            raise ChainError('%r is not a model id' % i)
        if not override and (i.lower() == 'auto' or 'haiku' in i.lower()):
            raise ChainError('%r is not allowed in the list (no auto, no Haiku)' % i)
    return list(ids)


def is_not_available(text):
    return bool(NOT_AVAILABLE.search(text))


def run_chain(ids, run, log=print):
    """Try `run(model)` -> (returncode, stdout, stderr) in order. Returns (model, stdout) of the first success.
    Only the "not available" error goes on to the next id, anything else raises ChainError."""
    for model in ids:
        log('trying model %s' % model)
        code, out, err = run(model)
        if err.strip():
            log('copilot said: %s' % err.strip()[:2000])
        if code == 0:
            return model, out
        if is_not_available(out + '\n' + err):
            log('model %s is not available to this account' % model)
            continue
        raise ChainError('copilot failed with exit code %s for model %s (not a model error, so no other model is tried)' % (code, model))
    raise ChainError('none of the models is available to this account: %s' % ', '.join(ids))


def copilot_runner(prompt):
    def run(model):
        try:
            r = subprocess.run(['copilot', '--model', model, '-p', prompt, *COPILOT_ARGS], capture_output=True, text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return 124, '', 'timed out after %d s' % TIMEOUT
        return r.returncode, r.stdout, r.stderr
    return run


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument('--prompt', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--candidates', default='')
    p.add_argument('--override', default='')
    args = p.parse_args(argv)
    try:
        override = args.override.strip()
        ids = check_candidates([override] if override else args.candidates.split(), bool(override))
        with open(args.prompt, encoding='utf-8') as f:
            prompt = f.read()
        model, answer = run_chain(ids, copilot_runner(prompt))
    except (ChainError, OSError) as e:
        print('::error title=Release notes::%s' % e)
        return 1
    with open(args.out, 'w', encoding='utf-8') as f:
        f.write(answer)
    with open(os.path.join(os.path.dirname(os.path.abspath(args.out)), 'model.txt'), 'w', encoding='utf-8') as f:
        f.write(model + '\n')
    print('model used: %s' % model)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
            f.write('ran=true\nmodel=%s\n' % model)
    return 0


if __name__ == '__main__':
    sys.exit(main())
