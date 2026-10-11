#!/usr/bin/env python3
"""Split the native debug symbols out of a signed Play AAB and re-sign it.

ndk.debugSymbolLevel = FULL puts ~109 MiB of .dbg files in BUNDLE-METADATA, 70% of the 155 MiB
0.1.0 bundle. Play never ships them to devices, but they bloat the upload. Play also accepts the
same files as a separate "native debug symbols" zip (layout <abi>/<lib>.so.dbg), so: collect them
into that zip, drop them from the bundle, strip the old signature and sign again with the upload key.

Usage: split_native_symbols.py <aab> <out-symbols.zip>   (the AAB is rewritten in place)
Env (as in the release-aab job): RUN_SOLO_UPLOAD_KEYSTORE, RUN_SOLO_UPLOAD_STORE_PASSWORD,
RUN_SOLO_UPLOAD_KEY_PASSWORD, RUN_SOLO_UPLOAD_KEY_ALIAS (default "upload").
"""
import os
import subprocess
import sys
import zipfile

PREFIX = 'BUNDLE-METADATA/com.android.tools.build.debugsymbols/'
SIGNATURE_EXT = ('.SF', '.RSA', '.DSA', '.EC')


def is_signature(name):
    return name == 'META-INF/MANIFEST.MF' or (name.startswith('META-INF/') and name.endswith(SIGNATURE_EXT))


def main(aab, out_zip):
    before = os.path.getsize(aab)
    tmp = aab + '.tmp'
    n_sym = 0
    with zipfile.ZipFile(aab) as src, \
            zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as dst, \
            zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED) as sym:
        for info in src.infolist():
            name = info.filename
            if name.startswith(PREFIX):
                if not name.endswith('/'):
                    sym.writestr(name[len(PREFIX):], src.read(info))
                    n_sym += 1
            elif is_signature(name):
                continue
            else:
                dst.writestr(info, src.read(info), compress_type=info.compress_type)
    if n_sym == 0:
        os.remove(tmp)
        sys.exit(f'no native debug symbols in {aab}')
    os.replace(tmp, aab)
    subprocess.run([
        'jarsigner', '-keystore', os.environ['RUN_SOLO_UPLOAD_KEYSTORE'],
        '-storepass:env', 'RUN_SOLO_UPLOAD_STORE_PASSWORD',
        '-keypass:env', 'RUN_SOLO_UPLOAD_KEY_PASSWORD',
        aab, os.environ.get('RUN_SOLO_UPLOAD_KEY_ALIAS', 'upload'),
    ], check=True, stdout=subprocess.DEVNULL)
    print(f'AAB {before} -> {os.path.getsize(aab)} bytes; '
          f'{n_sym} symbol files -> {out_zip} ({os.path.getsize(out_zip)} bytes)')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
