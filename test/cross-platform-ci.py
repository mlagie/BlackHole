#!/usr/bin/env python3
"""Build native releases, then verify archives exchanged between CI hosts."""
import argparse,os,pathlib,shutil,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('--build',action='store_true');p.add_argument('--native');p.add_argument('--foreign');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent;os.chdir(root)
ext='.exe' if os.name=='nt' else ''
if a.build:
    def cabal(*args):return subprocess.run(['cabal',*args],check=True)
    cabal('update')
    if os.name=='nt':
        subprocess.run(['powershell','-NoProfile','-ExecutionPolicy','Bypass','-File','build-windows.ps1','-OutputDirectory','ci-release'],check=True)
    else:
        cabal('build','all','-fbundled-zstd')
        cabal('test','all','-fbundled-zstd','--test-show-details=direct','--test-options=+RTS -N2 -RTS')
    binary=pathlib.Path(subprocess.check_output(['cabal','list-bin','exe:blackhole','-fbundled-zstd'],text=True).strip())
    stage=root/'ci-release';stage.mkdir(exist_ok=True);target=stage/('blackhole'+ext);shutil.copy2(binary,target)
    subprocess.run([sys.executable,'test/portable-integration.py','--binary',str(target),'--fixture-output',str(stage/'fixture.bh')],check=True)
else:
    binary=pathlib.Path(a.native).resolve()/('blackhole'+ext)
    binary.chmod(0o755);fixture=pathlib.Path(a.foreign).resolve()/'fixture.bh'
    os.environ['BLACKHOLE_CLEAN_DLL_PATH']='1'
    subprocess.run([sys.executable,'test/portable-integration.py','--binary',str(binary),'--verify-fixture',str(fixture)],check=True)
