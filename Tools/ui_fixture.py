#!/usr/bin/env python3
"""Write disposable synthetic logs for manual UI checks.

Never reads or changes a real oMLX environment. Output goes to
`build/verification/live-test.log`, with generator state in `state.json`.

Actions:
    initial   start a fresh log with 20 request/scheduler/output cycles
    append    add the next cycle to the existing log
    rotate    rename the log to *.log.1 and start a new generation
    partial   append the first half of a record (no trailing newline)
    complete  finish the record started by `partial`
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / 'build' / 'verification'
LOG = ROOT / 'live-test.log'
STATE = ROOT / 'state.json'


def line(body, logger='omlx.server', level='TRACE'):
    return f'2026-11-20 22:30:00,000 - {logger} - {level} - [-] - {body}\n'


def add_cycle(messages, number):
    """Append one request with its scheduler and output records, then extend the history."""
    request = {'model': 'Synthetic verification model', 'messages': messages, 'tools': []}
    with LOG.open('a') as out:
        out.write(line('Incoming POST /v1/chat/completions — body: ' + json.dumps(request)))
        out.write(line(f'Added request test-{number} with {100 + number * 20} prompt tokens', 'omlx.scheduler', 'DEBUG'))
        out.write(line(f'Request test-{number} finished: stop, 10 tokens', 'omlx.scheduler', 'DEBUG'))
        out.write(line(f'Request test-{number} generated text:\nSynthetic output {number}', 'omlx.scheduler'))
    call = {'id': f'call-{number}', 'function': {'name': 'fixture_tool', 'arguments': json.dumps({'step': number})}}
    messages += [
        {'role': 'assistant', 'tool_calls': [call]},
        {'role': 'tool', 'tool_call_id': f'call-{number}', 'content': f'Synthetic result {number}'},
    ]
    STATE.write_text(json.dumps({'messages': messages, 'number': number}))


def main(action):
    ROOT.mkdir(parents=True, exist_ok=True)
    if action == 'initial':
        LOG.write_text('')
        messages = [
            {'role': 'system', 'content': 'Disposable test fixture; no tools are executed.'},
            {'role': 'user', 'content': 'Synthetic long interaction for Phase 2 verification'},
        ]
        for number in range(1, 21):
            add_cycle(messages, number)
    elif action == 'append':
        saved = json.loads(STATE.read_text())
        add_cycle(saved['messages'], saved['number'] + 1)
    elif action == 'rotate':
        LOG.rename(LOG.with_suffix('.log.1'))
        LOG.write_text('')
        add_cycle([{'role': 'user', 'content': 'Synthetic NEW generation after rotation'}], 1)
    elif action == 'partial':
        with LOG.open('a') as out:
            out.write('2026-11-20 22:30:00,000 - omlx.server - TRACE - [-] - Incom')
    elif action == 'complete':
        with LOG.open('a') as out:
            out.write('ing POST /v1/chat/completions — body: '
                      '{"messages":[{"role":"user","content":"Completed partial synthetic request"}]}\n')
    else:
        raise SystemExit('Choose initial, append, rotate, partial, or complete')
    print(LOG)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
