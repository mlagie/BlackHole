#!/usr/bin/env python3
"""Host-independent CLI roundtrips and Linux/Windows archive exchange fixtures."""
import argparse, hashlib, os, pathlib, subprocess, tempfile

def fixture(root):
    root.mkdir()
    (root/'empty directory').mkdir()
    data = {
        'space folder/é-file.txt': 'Unicode et chemins Windows / @ @@\n'.encode()*10000,
        'space folder/@literal.js': b'const repeatedIdentifier = "hello\\nworld";\n'*9000,
        'binary.bin': bytes(range(256))*67,
        'duplicate.bin': bytes(range(256))*67,
        'empty.txt': b'',
        '.gitignore': b'node_modules/\n',
    }
    for name,content in data.items():
        p=root/name; p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(content)
    return inventory(root)

def inventory(root):
    result={}
    for p in sorted(root.rglob('*')):
        name=p.relative_to(root).as_posix()
        if p.is_symlink(): result[name]=('link',os.readlink(p))
        elif p.is_dir(): result[name]=('directory',)
        else: result[name]=('file',p.stat().st_size,hashlib.sha256(p.read_bytes()).hexdigest())
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True)
    parser.add_argument('--fixture-output');parser.add_argument('--verify-fixture')
    args=parser.parse_args();binary=str(pathlib.Path(args.binary).resolve())
    def run(*command):
        env=os.environ.copy()
        if os.name=='nt' and env.get('BLACKHOLE_CLEAN_DLL_PATH')=='1':
            env['PATH']=str(pathlib.Path(env['SystemRoot'])/'System32')
        subprocess.run([binary,*map(str,command),'+RTS','-N2','-RTS'],check=True,env=env)
    with tempfile.TemporaryDirectory(prefix='blackhole-portable-') as folder:
        temp=pathlib.Path(folder);source=temp/'project';expected=fixture(source)
        if args.verify_fixture:
            out=temp/'foreign';run('test',args.verify_fixture);run('extract',args.verify_fixture,'-o',out)
            assert inventory(out/'project')==expected
            print('Foreign archive: exact tree and SHA256 match.');return
        for mode in ('default','turbo','balanced','direct'):
            archive=temp/(mode+'.bh');out=temp/mode
            flags=[] if mode=='default' else ['--'+mode]
            run('compress',source,*flags,'-o',archive);run('test',archive)
            run('extract',archive,'-o',out);assert inventory(out/'project')==expected
            if mode=='default' and args.fixture_output:
                pathlib.Path(args.fixture_output).write_bytes(archive.read_bytes())
        archive=temp/'automatic.bh';run('compress',source,'-o',archive);run(archive)
        assert inventory(temp/'automatic'/'project')==expected
        # Output names that look like options must not become quality flags.
        archive=temp/'--turbo';run('compress',source,'-o',archive);run('test',archive)
    print('Portable CLI: all roundtrips and exact inventories passed.')
if __name__=='__main__':main()
