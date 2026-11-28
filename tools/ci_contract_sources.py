"""Same-attempt native source handoff for disposable Linux CI jobs, not a cache.

The workflow owns artifact provenance and the launcher owns worker admission.
Assumes resolve-workspace, trusted local installations and no concurrent writers.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urljoin, urlsplit
import zipfile


MAX_JSON = 4 * 1024 * 1024
MAX_ZIP = 1024 * 1024
GENERATE = ['dart', 'tools/adele.dart', 'generate']  # Full, configured defaults.


def require(ok, message):
    if not ok:
        raise ValueError(message)


def decode(data):
    def unique(pairs):
        result = dict(pairs)
        require(len(result) == len(pairs), 'duplicate JSON key')
        return result

    return json.loads(data.decode('utf-8'), object_pairs_hook=unique)


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                      allow_nan=False).encode('utf-8')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def phase(start, label):
    now = time.monotonic()
    print(f'contract-sources: {label} ({now - start:.3f}s)', flush=True)
    return now


def regular_size(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
            f'not a standalone regular file: {path}')
    return info.st_size


def git(*args):
    return subprocess.check_output(['git', *args]).decode().rstrip('\n')


def require_clean():
    require(not git('status', '--porcelain', '--untracked-files=all'), 'dirty checkout or index')


def workflow(mode):
    env = os.environ
    require(sys.platform == 'linux' and env['RUNNER_OS'] == 'Linux' and
            env['GITHUB_ACTIONS'] == 'true', 'requires Linux GitHub Actions')
    expected_job = 'discover-test-targets' if mode == 'produce' else 'test-target'
    require(env['GITHUB_JOB'] == expected_job, f'requires job {expected_job}')
    repo, ref = env['GITHUB_REPOSITORY'], env['GITHUB_REF']
    event = env['GITHUB_EVENT_NAME']
    require((event == 'push' and ref.startswith('refs/heads/')) or
            (event == 'pull_request' and re.fullmatch(r'refs/pull/[1-9][0-9]*/merge', ref)),
            'not an ordinary push or pull request')
    require(re.fullmatch(r'[\w.-]+/[\w.-]+', repo) and
            env['GITHUB_WORKFLOW_REF'] == f'{repo}/.github/workflows/ci.yaml@{ref}',
            'wrong CI workflow')
    require(all(re.fullmatch('[1-9][0-9]*', env[k]) for k in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT')),
            'missing workflow run or attempt')
    require(Path.cwd() == Path(env['GITHUB_WORKSPACE']).resolve() == Path(git('rev-parse', '--show-toplevel')),
            'not running at the checkout root')
    require(git('rev-parse', 'HEAD') == env['GITHUB_SHA'], 'checkout is not GITHUB_SHA')
    return {key: env['GITHUB_' + key] for key in
            ('REPOSITORY', 'WORKFLOW_REF', 'EVENT_NAME', 'RUN_ID', 'RUN_ATTEMPT', 'SHA')}


def inventory(tracked):
    # Same ordered line-list and extension convention as contract_codegen's CLI.
    rows = []
    for line in Path('contract_codegen.yaml').read_text().splitlines():
        line = line.strip()
        if line in ('', 'sources:') or line.startswith('#'):
            continue
        require(line.startswith('- '), 'expected configured sources list')
        name = line[2:].strip()
        require(re.fullmatch(r'(?:packages|plugins)/(?:[\w-]+/)*[\w-]+\.dart', name, re.ASCII),
                'unsafe or unsupported source path')
        source = Path(name)
        require(name in tracked and source.resolve(strict=True) == Path.cwd() / source,
                f'untracked or linked declaration: {name}')
        regular_size(source)
        rows.append((source, source.with_suffix('.g.dart')))
    targets = [str(target) for _, target in rows]
    require(0 < len(rows) <= 128 and len(set(targets)) == len(rows), 'empty or duplicate inventory')
    require(tracked.isdisjoint(targets) and set(git('check-ignore', '--', *targets).splitlines()) == set(targets),
            'configured outputs must be untracked and ignored')
    return rows


def check_resolver_paths(tracked):
    # A nearer ignored config can change the analyzer context or the generator
    # entrypoint without changing either Git status or the root package config.
    directories = {parent for name in tracked if name.endswith(('.dart', 'pubspec.yaml'))
                   for parent in Path(name).parents}
    for directory in directories:
        shadows = ['pubspec_overrides.yaml', '.packages']
        if directory != Path('.'):
            shadows.append('.dart_tool/package_config.json')
        for shadow in shadows:
            require(not os.path.lexists(directory / shadow), f'unexpected resolver: {directory / shadow}')


def toolchain():
    sdk = Path(os.environ['FLUTTER_ROOT']).resolve(strict=True)
    for cmd, allowed in [('flutter', [sdk / 'bin/flutter']),
                         ('dart', [sdk / 'bin/dart', sdk / 'bin/cache/dart-sdk/bin/dart'])]:
        executable = shutil.which(cmd)
        require(executable and Path(executable).resolve() in allowed, f'{cmd} not from pinned Flutter SDK')
    report = decode(subprocess.check_output(['flutter', '--version', '--machine']))
    versions = {key: report[field] for key, field in [('flutter', 'frameworkVersion'),
                ('flutterRevision', 'frameworkRevision'), ('engineRevision', 'engineRevision'),
                ('dart', 'dartSdkVersion')]}
    pins = decode(Path('toolchain.json').read_bytes())
    for key, version in versions.items():
        require(version == pins[key], f'toolchain mismatch for {key}: expected {pins[key]}, got {version}')
    require(Path(report['flutterRoot']).resolve() == sdk, 'Flutter reports another SDK root')
    flutter_pins = [line.split()[1:] for line in Path('.tool-versions').read_text().splitlines()
                    if line.split()[:1] == ['flutter']]
    require(flutter_pins == [[f"{versions['flutter']}-{report['channel']}"]], 'Flutter .tool-versions mismatch')
    dart = subprocess.check_output(['dart', '--version'], stderr=subprocess.STDOUT, text=True).strip()
    require(dart.startswith(f"Dart SDK version: {versions['dart']} ") and 'on "linux_' in dart,
            'bundled Dart version/platform mismatch')
    return sdk, dict(versions, channel=report['channel'], runtime=dart)


def file_uri(value, base=''):
    uri = urlsplit(urljoin(base, value))
    require(uri.scheme == 'file' and not (uri.netloc or uri.query or uri.fragment) and uri.path.startswith('/'),
            'unsupported package resolution URI')
    return Path(unquote(uri.path)).resolve(strict=True)


def resolution(sdk, versions):
    pc = Path('.dart_tool/package_config.json').absolute()
    pg = pc.with_name('package_graph.json')
    for path in (pc, pg):
        require(path.resolve(strict=True) == path, 'linked workspace resolution')
        regular_size(path)
    cfg = decode(pc.read_bytes())
    cache = Path(os.environ.get('PUB_CACHE', Path.home() / '.pub-cache')).resolve(strict=True)
    require(set(cfg) == {'configVersion', 'packages', 'flutterRoot', 'pubCache', 'generator',
                         'generatorVersion', 'flutterVersion'} and cfg['configVersion'] == 2 and
            cfg['generator'] == 'pub' and cfg['generatorVersion'] == versions['dart'] and
            cfg['flutterVersion'] == versions['flutter'] and file_uri(cfg['flutterRoot']) == sdk and
            file_uri(cfg['pubCache']) == cache, 'root package config/provider mismatch')
    packages = {}
    for p in cfg['packages']:
        require(set(p) == {'name', 'packageUri', 'rootUri', 'languageVersion'} and
                p['packageUri'] == 'lib/' and p['name'] not in packages, 'unsupported or duplicate package')
        root = file_uri(p['rootUri'], pc.as_uri())
        for label, anchor in [('checkout', Path.cwd()), ('sdk', sdk), ('hosted', cache / 'hosted')]:
            if root.is_relative_to(anchor):
                packages[p['name']] = [label, str(root.relative_to(anchor)), p['packageUri'], p['languageVersion']]
                break
        else:
            raise ValueError('unsupported package origin')
    graph = decode(pg.read_bytes())
    require(set(graph) == {'configVersion', 'packages', 'roots'} and graph['configVersion'] == 1,
            'unsupported package graph')
    graph['roots'].sort()
    graph['packages'].sort(key=lambda p: p['name'])
    require(packages and sorted(packages) == [p['name'] for p in graph['packages']], 'graph/config packages differ')
    for p in graph['packages']:
        for field in ('dependencies', 'devDependencies'):
            if field in p:
                p[field].sort()
    return {'packages': digest(encode(packages)), 'graph': digest(encode(graph)),
            'lock': digest(Path('pubspec.lock').read_bytes())}


def identity(mode):
    run = workflow(mode)
    require_clean()
    tracked = set(git('ls-files', '-z').split('\0'))
    require({'.tool-versions', 'toolchain.json', 'contract_codegen.yaml', 'pubspec.lock'} <= tracked,
            'missing tracked identity input')
    rows = inventory(tracked)
    check_resolver_paths(tracked)
    sdk, versions = toolchain()
    return {'workflow': run, 'tree': git('rev-parse', 'HEAD^{tree}'), 'sdk': versions,
            'resolution': resolution(sdk, versions), 'command': GENERATE,
            'config': digest(Path('contract_codegen.yaml').read_bytes())}, rows


def native(source, data):
    require(data.startswith(b'// Generated by ADELE contract_codegen (native transport).\n') and
            f"\npart of '{source.name}';\n".encode() in data, f'not the native sibling of {source}')


def produce(artifact):
    start = time.monotonic()
    ident, rows = identity('produce')
    require(not os.path.lexists(artifact), 'artifact already exists')
    require(all(not os.path.lexists(target) for _, target in rows), 'producer requires all configured parts absent')
    start = phase(start, f'producer identity, {len(rows)} absent')
    subprocess.run(GENERATE, check=True)
    start = phase(start, 'full generation')
    require(identity('produce') == (ident, rows), 'identity changed during generation')
    start = phase(start, 'producer identity rechecked')
    outputs = []
    total = 0
    for source, target in rows:
        total += regular_size(target)
        require(total <= MAX_JSON, 'generated sources exceed limit')
        data = target.read_bytes()
        native(source, data)
        outputs.append({'path': str(target), 'size': len(data), 'sha256': digest(data), 'text': data.decode('utf-8')})
    raw = encode({'version': 1, 'identity': ident, 'outputs': outputs})
    require(len(raw) <= MAX_JSON, 'JSON payload exceeds limit')
    with artifact.open('xb') as f:
        f.write(raw)
    phase(start, f'published {len(outputs)} parts, {total} native bytes, {len(raw)} JSON bytes, sdk={ident["sdk"]}')


def read_zip(artifact):
    require(regular_size(artifact) <= MAX_ZIP, 'ZIP exceeds limit')
    with zipfile.ZipFile(artifact) as archive:
        entries = archive.infolist()
        require(len(entries) == 1, 'expected exactly one ZIP entry')
        info = entries[0]
        # Linux upload-artifact@v4 stores the Unix file type. The low DOS
        # attributes must not mark a volume label, directory, device or reparse point.
        require(info.orig_filename == 'contracts.json' and info.create_system == 3 and
                stat.S_ISREG(info.external_attr >> 16) and not info.external_attr & 0x458,
                'not a regular contracts.json')
        require(0 < info.file_size <= MAX_JSON and not info.flag_bits & 1 and
                info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), 'unsupported ZIP entry')
        with archive.open(info) as entry:
            raw = entry.read(MAX_JSON + 1)
        require(len(raw) == info.file_size, 'ZIP entry size mismatch')
    return decode(raw)


def validate(bundle, ident, rows):
    require(isinstance(bundle, dict) and set(bundle) == {'version', 'identity', 'outputs'} and
            type(bundle['version']) is int and bundle['version'] == 1, 'unexpected payload schema')
    require(encode(bundle['identity']) == encode(ident), 'payload identity differs from local job')
    outputs = bundle['outputs']
    require(isinstance(outputs, list) and len(outputs) == len(rows), 'wrong output inventory')
    batch = []
    for entry, (source, target) in zip(outputs, rows):
        require(isinstance(entry, dict) and set(entry) == {'path', 'size', 'sha256', 'text'} and
                entry['path'] == str(target) and type(entry['size']) is int and isinstance(entry['text'], str),
                'unexpected output entry')
        data = entry['text'].encode('utf-8')
        require(len(data) == entry['size'] and digest(data) == entry['sha256'], f'output digest/size mismatch: {target}')
        native(source, data)
        require(target.parent.resolve(strict=True) == Path.cwd() / target.parent, 'linked destination parent')
        if os.path.lexists(target):
            regular_size(target)
        batch.append((target, data))
    return batch


def consume(artifact):
    start = time.monotonic()
    ident, rows = identity('consume')
    start = phase(start, 'consumer identity')
    batch = validate(read_zip(artifact), ident, rows)
    start = phase(start, f'validated {len(rows)} parts, {sum(len(data) for _, data in batch)} native bytes')
    staged = []
    try:
        for target, data in batch:
            if target.exists() and regular_size(target) == len(data) and target.read_bytes() == data:
                continue
            with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as f:
                staged.append((Path(f.name), target))
                f.write(data)
                os.fchmod(f.fileno(), 0o644)
        for tmp, target in staged:
            tmp.replace(target)
        for target, data in batch:
            require(regular_size(target) == len(data) and target.read_bytes() == data, f'readback failed: {target}')
        require_clean()
    finally:
        for tmp, _ in staged:
            tmp.unlink(missing_ok=True)
    phase(start, f'replaced {len(staged)}, verified {len(batch)} by readback')


def main():
    require(len(sys.argv) == 3 and sys.argv[1] in ('produce', 'consume'), 'expected: produce JSON | consume ZIP')
    mode, path = sys.argv[1], Path(sys.argv[2])
    name = 'contracts.json' if mode == 'produce' else 'contracts.zip'
    require(path.is_absolute() and path == Path(os.environ['RUNNER_TEMP']) / name, f'expected $RUNNER_TEMP/{name}')
    (produce if mode == 'produce' else consume)(path)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, RuntimeError, zipfile.BadZipFile, subprocess.SubprocessError) as e:
        sys.exit(f'contract-sources rejected: {e}')
