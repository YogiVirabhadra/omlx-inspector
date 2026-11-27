#!/usr/bin/env python3
"""Disposable UI fixtures only. Never reads or changes the observed oMLX environment."""
import json
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'build' / 'verification'
root.mkdir(parents=True, exist_ok=True)
path = root / 'live-test.log'
state = root / 'state.json'
def line(body, logger='omlx.server', level='TRACE'):
    return f'2026-11-20 22:30:00,000 - {logger} - {level} - [-] - {body}\n'
def add(messages, number):
    with path.open('a') as out:
        out.write(line('Incoming POST /v1/chat/completions — body: ' + json.dumps({'model':'Synthetic verification model', 'messages': messages, 'tools':[]})))
        out.write(line(f'Added request test-{number} with {100 + number * 20} prompt tokens', 'omlx.scheduler', 'DEBUG'))
        out.write(line(f'Request test-{number} finished: stop, 10 tokens', 'omlx.scheduler', 'DEBUG'))
        out.write(line(f'Request test-{number} generated text:\nSynthetic output {number}', 'omlx.scheduler'))
    messages += [{'role':'assistant', 'tool_calls':[{'id':f'call-{number}', 'function':{'name':'fixture_tool', 'arguments':json.dumps({'step':number})}}]}, {'role':'tool','tool_call_id':f'call-{number}','content':f'Synthetic result {number}'}]
    state.write_text(json.dumps({'messages':messages, 'number':number}))
action = sys.argv[1]
if action == 'initial':
    path.write_text('')
    messages = [{'role':'system','content':'Disposable test fixture; no tools are executed.'}, {'role':'user','content':'Synthetic long interaction for Phase 2 verification'}]
    for n in range(1,21): add(messages,n)
elif action == 'append':
    saved = json.loads(state.read_text()); add(saved['messages'],saved['number']+1)
elif action == 'rotate':
    path.rename(path.with_suffix('.log.1'))
    path.write_text('')
    add([{'role':'user','content':'Synthetic NEW generation after rotation'}],1)
elif action == 'partial':
    with path.open('a') as out: out.write('2026-11-20 22:30:00,000 - omlx.server - TRACE - [-] - Incom')
elif action == 'complete':
    with path.open('a') as out: out.write('ing POST /v1/chat/completions — body: {"messages":[{"role":"user","content":"Completed partial synthetic request"}]}\n')
else: raise SystemExit('Choose initial, append, rotate, partial, or complete')
print(path)
