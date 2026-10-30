#!/usr/bin/env python3
"""Hace que la app aparezca en el launcher de Android TV (Capacitor).
Uso: python3 patch_tv.py   (ejecutar en la raiz del repo, donde esta la carpeta android/)"""
import os, re, shutil, sys
root = sys.argv[1] if len(sys.argv) > 1 else "."
mf = os.path.join(root, "android/app/src/main/AndroidManifest.xml")
if not os.path.exists(mf): sys.exit("No encuentro " + mf + " (ejecuta desde la raiz del repo)")
s = open(mf, encoding="utf-8").read()

# 1) uses-feature
feats = ('    <uses-feature android:name="android.software.leanback" android:required="false" />\n'
         '    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />\n')
if "android.software.leanback" not in s:
    s = re.sub(r'(<manifest[^>]*>\s*\n)', lambda m: m.group(1) + feats, s, count=1)

# 2) banner en <application>
if "android:banner" not in s:
    s = re.sub(r'<application', '<application\n        android:banner="@drawable/banner"', s, count=1)

# 3) intent-filter LEANBACK_LAUNCHER en la activity principal
if "LEANBACK_LAUNCHER" not in s:
    intent = ('            <intent-filter>\n'
              '                <action android:name="android.intent.action.MAIN" />\n'
              '                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />\n'
              '            </intent-filter>\n')
    m = re.search(r'(<activity\b.*?)(</activity>)', s, re.S)
    if not m: sys.exit("No encontre <activity> en el manifest")
    s = s[:m.end(1)] + intent + "        " + s[m.start(2):]

open(mf, "w", encoding="utf-8").write(s)

# 4) banner.png
d = os.path.join(root, "android/app/src/main/res/drawable")
os.makedirs(d, exist_ok=True)
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "banner.png"), os.path.join(d, "banner.png"))
print("Listo: manifest parcheado y banner copiado. Haz commit y compila el APK.")
