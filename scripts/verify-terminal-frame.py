#!/usr/bin/env python3
"""VM-only owned app: exact renderer export, lifetime guards, CLI/page parity."""
import base64
import hashlib
import json
import struct
from api_fixture import ROOT, AppFixture, eventually
from plugin_package_fixture import package_fixture

with AppFixture('terminal-frame') as app:
    app.capture_contracts()
    eventually('authenticated prompt', lambda: app.rpc('context.get')['terminal']['state'] == 'prompt')
    app.rpc('command.run', id='welcome.read')
    epoch = app.rpc('api.describe')['appInstanceId']
    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    params = dict(pane='p1', sessionId=session, expectedInstanceId=epoch)

    def frame(**changes):
        return app.rpc('terminal.frame', **(params | changes))

    def verify(value):
        assert value['paneId'] == 'p1' and value['sessionId'] == session
        assert value['appInstanceId'] == epoch and value['freshness'] == 'renderedForRequest'
        assert value['mimeType'] == 'image/png' and value['colorSpace'] == 'Display P3'
        png = base64.b64decode(value['pngBase64'], validate=True)
        assert 0 < len(png) <= 512 * 1024 and png[:8] == b'\x89PNG\r\n\x1a\n'
        assert struct.unpack('>II', png[16:24]) == (value['pixelWidth'], value['pixelHeight'])
        assert hashlib.sha256(png).hexdigest() == value['frameId'] == value['contentHash']
        return png

    app.rpc('terminal.frame', pane='p1', error=-32602)
    app.rpc('terminal.frame', pane='p1', sessionId=session, expectedInstanceId=epoch, scope='global', error=-32602)
    frame(sessionId='stale', error=-32022)
    frame(expectedInstanceId='stale', error=-32050)
    before = app.rpc('workspace.snapshot')
    first = frame()
    verify(first)
    assert before['workspaceRevision'] == app.rpc('workspace.snapshot')['workspaceRevision']
    app.rpc('terminal.run', pane='p1', command="printf '\\033[41mFRAME_%s 日本語 🦊\\033[0m\\n' FIRST")
    eventually('new output', lambda: 'FRAME_FIRST' in app.rpc('terminal.capture', pane='p1')['text'])
    before = app.rpc('workspace.snapshot')
    second = frame()
    second_png = verify(second)
    assert second['contentHash'] != first['contentHash']
    assert second['requestId'] != first['requestId']
    assert second['observedAtMillis'] >= first['observedAtMillis']
    after = app.rpc('workspace.snapshot')
    assert before['workspaceRevision'] == after['workspaceRevision'], 'Capture changed workspace geometry/focus'
    (ROOT / 'artifacts/terminal-frame.png').write_bytes(second_png)
    cli = app.cli('terminal', 'frame', '--pane', 'p1', '--session-id', session, '--expected-instance-id', epoch)
    verify(cli)

    # Guarded pointer/selection/scroll are explicit mutations of this fixture's
    # terminal only. This script is VM-only, never an ambient host smoke test.
    def geometry(value):
        return {key: value[key] for key in ('pointWidth', 'pointHeight', 'pixelWidth', 'pixelHeight')}
    interaction = params | dict(geometry=geometry(frame()), point=dict(x=1, y=1))
    app.rpc('terminal.pointer', **(interaction | dict(action='down')), error=-32602)
    app.rpc('terminal.scroll', **(interaction | dict(deltaX=0, deltaY=0)), error=-32602)
    stale_geometry = geometry(frame()) | dict(pointWidth=0.5)
    app.rpc('terminal.pointer', **(interaction | dict(geometry=stale_geometry, action='click')), error=-32602)
    stale_geometry = geometry(frame()) | dict(pointWidth=interaction['geometry']['pointWidth'] + 1)
    app.rpc('terminal.pointer', **(interaction | dict(geometry=stale_geometry, action='click')), error=-32022)
    before = app.rpc('workspace.snapshot')
    dispatch = app.rpc('terminal.pointer', **(interaction | dict(action='move')))
    assert dispatch == dict(paneId='p1', sessionId=session, appInstanceId=epoch, delivery='dispatched')
    # Create enough retained rows for real scrolling. Hide the cursor so a blink
    # cannot masquerade as changed viewport pixels; round-trip must be exact.
    app.rpc('terminal.run', pane='p1', command="printf '\\033[?25l'; for i in {1..200}; do printf 'SCROLL_FIXTURE_%03d\\n' $i; done")
    bottom = frame()
    interaction['geometry'] = geometry(bottom)
    app.rpc('terminal.scroll', **(interaction | dict(deltaX=0, deltaY=100)))
    top = frame()
    assert top['contentHash'] != bottom['contentHash'], 'Wheel up did not change the native viewport'
    app.rpc('terminal.scroll', **(interaction | dict(deltaX=0, deltaY=-100)))
    restored = frame()
    assert restored['contentHash'] == bottom['contentHash'], 'Wheel down did not restore exact bottom pixels'
    (ROOT / 'artifacts/terminal-frame-history-top.png').write_bytes(verify(top))
    (ROOT / 'artifacts/terminal-frame-history-bottom.png').write_bytes(verify(bottom))
    after = app.rpc('workspace.snapshot')
    assert before['workspaceRevision'] == after['workspaceRevision'], 'Interaction implicitly changed workspace/focus'
    app.rpc('terminal.run', pane='p1', command="printf '\\033[H\\033[2JSELECTION_FIXTURE_NATIVE_TEXT\\n'")
    interaction['geometry'] = geometry(frame())
    app.rpc('terminal.pointer', **(interaction | dict(action='drag', to=dict(x=min(220, interaction['geometry']['pointWidth'] - 1), y=1))))
    selected = app.rpc('terminal.selection', **params)
    assert selected['hasSelection'] and selected['text'], 'Native drag did not create a selection'
    assert len(selected['text'].encode()) <= 128 * 1024
    assert app.cli('terminal', 'selection', '--pane', 'p1', '--session-id', session, '--expected-instance-id', epoch) == selected

    assets = app.root / 'frame-panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Frame fixture</title>')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='frame.fixture', title='Frame fixture', source=dict(kind='directory', path=str(assets))), app.root))
    panel = app.rpc('command.run', id='split.right', pane='p1', focus='preserve')['paneId']
    app.rpc('command.run', id='pane.type', pane=panel, type='frame.fixture', force=True)
    def js(script):
        return app.rpc('debug.pluginEval', pane=panel, script=script)
    eventually('plugin bridge', lambda: js('typeof workspace') == 'object')
    verify(js('await workspace.terminal.frame(' + json.dumps(params) + ')'))
    assert js('await workspace.terminal.selection(' + json.dumps(params) + ')') == selected
    interaction['geometry'] = geometry(frame())
    assert js('await workspace.terminal.pointer(' + json.dumps(interaction | dict(action='move')) + ')')['delivery'] == 'dispatched'
    assert js('await workspace.terminal.scroll(' + json.dumps(interaction | dict(deltaX=0, deltaY=1)) + ')')['delivery'] == 'dispatched'

    # An ordinary page still has no bridge; this capability adds no origin bypass.
    app.rpc('command.run', id='pane.type', pane=panel, type='browser', force=True)
    assert app.rpc('browser.eval', pane=panel, script='typeof window.workspace') == 'undefined'
    app.rpc('command.run', id='pane.type', pane='p1', type='browser', force=True)
    app.rpc('command.run', id='pane.type', pane='p1', type='terminal', force=True)
    frame(error=-32022)

print('PASS terminal frame PNG, changed output, exact history scroll round-trip, native selection, lifetime/geometry guards and CLI/page parity')
