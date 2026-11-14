"""Verify GitHub Actions concurrency expressions in tests.yml and build-mac-app.yml."""
from pathlib import Path
import re
import unittest

try:
    import yaml
except ImportError:  # pragma: no cover - fallback when PyYAML is absent
    yaml = None

WORKFLOWS_DIR = Path(__file__).resolve().parents[2] / 'workflows'
TARGET_WORKFLOWS = ('tests.yml', 'build-mac-app.yml')
EXPR_RE = re.compile(r'\$\{\{\s*((?:(?!\}\}).)*?)\s*\}\}')
TOKEN_RE = re.compile(r"\s*('(?:[^'\\]|\\.)*'|==|!=|&&|\|\||[()]|[A-Za-z_][A-Za-z0-9_.-]*|\d+)\s*")


def _load_workflow(path):
    text = path.read_text(encoding='utf-8')
    if yaml is not None:
        data = yaml.safe_load(text)
        triggers = data.get('on') if 'on' in data else data.get(True, {})
        return {
            'name': data['name'],
            'on': triggers,
            'concurrency': data.get('concurrency', {}),
        }
    return _parse_minimal_yaml(text)


def _parse_minimal_yaml(text):
    """Extract top-level name, on.push, and concurrency blocks without PyYAML."""
    lines = text.splitlines()
    result = {'name': '', 'on': {}, 'concurrency': {}}
    section = None
    sub_section = None
    for raw in lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(raw) - len(raw.lstrip(' '))
        if indent == 0 and ':' in stripped:
            key, val = stripped.split(':', 1)
            section = key.strip()
            sub_section = None
            if section == 'name':
                result['name'] = val.strip().strip("'\"")
        elif section == 'concurrency' and indent == 2 and ':' in stripped:
            key, val = stripped.split(':', 1)
            result['concurrency'][key.strip()] = val.strip()
        elif section == 'on' and indent == 2 and ':' in stripped:
            key, _ = stripped.split(':', 1)
            sub_section = key.strip()
            result['on'].setdefault(sub_section, {})
        elif section == 'on' and sub_section == 'push' and indent == 4 and ':' in stripped:
            key, val = stripped.split(':', 1)
            result['on']['push'][key.strip()] = val.strip()
    return result


def _tokenize(expr):
    tokens = []
    pos = 0
    while pos < len(expr):
        match = TOKEN_RE.match(expr, pos)
        if not match:
            raise ValueError(f'Unexpected token in expression at {pos}: {expr[pos:]}')
        tokens.append(match.group(1))
        pos = match.end()
    return tokens


def _resolve_path(path, ctx):
    if path == 'true':
        return True
    if path == 'false':
        return False
    if path == 'null':
        return None
    if path.isdigit():
        return int(path)
    cur = ctx
    for part in path.split('.'):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur


class _ExprParser:
    def __init__(self, tokens, ctx):
        self.tokens = tokens
        self.ctx = ctx
        self.pos = 0

    def _peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def _consume(self):
        tok = self.tokens[self.pos]
        self.pos += 1
        return tok

    def parse(self):
        val = self._parse_or()
        if self.pos != len(self.tokens):
            raise ValueError(f'Trailing tokens: {self.tokens[self.pos:]}')
        return val

    def _parse_or(self):
        left = self._parse_and()
        while self._peek() == '||':
            self._consume()
            right = self._parse_and()
            left = left if left else right
        return left

    def _parse_and(self):
        left = self._parse_eq()
        while self._peek() == '&&':
            self._consume()
            right = self._parse_eq()
            left = right if left else left
        return left

    def _parse_eq(self):
        left = self._parse_atom()
        while self._peek() in ('==', '!='):
            op = self._consume()
            right = self._parse_atom()
            left = (left == right) if op == '==' else (left != right)
        return left

    def _parse_atom(self):
        tok = self._peek()
        if tok is None:
            raise ValueError('Unexpected end of expression')
        if tok == '(':
            self._consume()
            val = self._parse_or()
            if self._consume() != ')':
                raise ValueError('Expected closing parenthesis')
            return val
        self._consume()
        if tok.startswith("'") and tok.endswith("'"):
            return tok[1:-1]
        return _resolve_path(tok, self.ctx)


def _eval_expr(expr, ctx):
    return _ExprParser(_tokenize(expr), ctx).parse()


def _eval_value(raw, ctx):
    if isinstance(raw, bool):
        return raw
    text = str(raw).strip()
    full = EXPR_RE.fullmatch(text)
    if full:
        return _eval_expr(full.group(1), ctx)
    return EXPR_RE.sub(lambda m: '' if (v := _eval_expr(m.group(1), ctx)) is None else str(v), text)


def _make_context(workflow_name, event_name, ref, run_id, pr_number=None):
    event = {}
    if pr_number is not None:
        event['pull_request'] = {'number': pr_number}
    return {
        'github': {
            'workflow': workflow_name,
            'event_name': event_name,
            'ref': ref,
            'run_id': run_id,
            'event': event,
        }
    }


class WorkflowConcurrencyTests(unittest.TestCase):
    def _eval_concurrency(self, filename, event_name, ref, run_id, pr_number=None):
        wf = _load_workflow(WORKFLOWS_DIR / filename)
        ctx = _make_context(wf['name'], event_name, ref, run_id, pr_number=pr_number)
        conc = wf['concurrency']
        group = str(_eval_value(conc['group'], ctx))
        cancel = bool(_eval_value(conc['cancel-in-progress'], ctx))
        return wf['name'], group, cancel

    def test_pull_request_cancels_within_same_pr_group(self):
        for filename in TARGET_WORKFLOWS:
            with self.subTest(workflow=filename):
                wf_name, group, cancel = self._eval_concurrency(
                    filename, 'pull_request', 'refs/pull/1325/merge', 100, pr_number=1325
                )
                self.assertEqual(group, f'{wf_name}-1325')
                self.assertTrue(cancel)

    def test_push_to_main_coalesces_across_runs(self):
        for filename in TARGET_WORKFLOWS:
            with self.subTest(workflow=filename):
                wf_name, group_1, cancel_1 = self._eval_concurrency(
                    filename, 'push', 'refs/heads/main', 101
                )
                _, group_2, cancel_2 = self._eval_concurrency(
                    filename, 'push', 'refs/heads/main', 102
                )
                self.assertEqual(group_1, f'{wf_name}-main')
                self.assertEqual(group_1, group_2)
                self.assertTrue(cancel_1)
                self.assertTrue(cancel_2)

    def test_push_to_release_tag_keeps_isolated_non_cancellable_runs(self):
        for filename in TARGET_WORKFLOWS:
            with self.subTest(workflow=filename):
                wf_name, group_1, cancel_1 = self._eval_concurrency(
                    filename, 'push', 'refs/tags/v1.5.0-rc4', 201
                )
                _, group_2, cancel_2 = self._eval_concurrency(
                    filename, 'push', 'refs/tags/v1.5.0-rc4', 202
                )
                self.assertEqual(group_1, f'{wf_name}-201')
                self.assertEqual(group_2, f'{wf_name}-202')
                self.assertNotEqual(group_1, group_2)
                self.assertFalse(cancel_1)
                self.assertFalse(cancel_2)

    def test_workflow_dispatch_on_main_is_isolated_and_non_cancellable(self):
        for filename in TARGET_WORKFLOWS:
            with self.subTest(workflow=filename):
                wf_name, group, cancel = self._eval_concurrency(
                    filename, 'workflow_dispatch', 'refs/heads/main', 301
                )
                self.assertEqual(group, f'{wf_name}-301')
                self.assertNotEqual(group, f'{wf_name}-main')
                self.assertFalse(cancel)

    def test_workflow_dispatch_on_feature_branch_is_isolated_and_non_cancellable(self):
        for filename in TARGET_WORKFLOWS:
            with self.subTest(workflow=filename):
                wf_name, group, cancel = self._eval_concurrency(
                    filename, 'workflow_dispatch', 'refs/heads/feature', 302
                )
                self.assertEqual(group, f'{wf_name}-302')
                self.assertFalse(cancel)

    def test_build_qt_does_not_push_trigger_on_main(self):
        wf = _load_workflow(WORKFLOWS_DIR / 'build-qt.yml')
        push_cfg = wf['on'].get('push', {})
        self.assertNotIn('branches', push_cfg)
        self.assertIn('tags', push_cfg)
        self.assertIn('workflow_dispatch', wf['on'])


if __name__ == '__main__':
    unittest.main()
