#!/usr/bin/env bash
set -euo pipefail

# 1) Web de la app
rm -rf www android
mkdir www
cp index.html www/
[ -f logo.png ] && cp logo.png www/

# 2) Proyecto Android
npx cap add android
unzip -oq glystv-res.zip -d android/app/src/main/res
PKG=android/app/src/main/java/com/glystv/app
MAN=android/app/src/main/AndroidManifest.xml

cat > $PKG/MainActivity.java <<'JAVA'
package com.glystv.app;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
  @Override
  public void onCreate(Bundle savedInstanceState) {
    registerPlugin(NativePlayerPlugin.class);
    registerPlugin(RemoteSetupPlugin.class);
    super.onCreate(savedInstanceState);
  }

  @Override
  public void onBackPressed() {
    NativePlayerPlugin p = NativePlayerPlugin.instance;
    if (p != null && p.handleBack()) return;
    super.onBackPressed();
  }
}
JAVA

cat > $PKG/NativePlayerPlugin.java <<'JAVA'
package com.glystv.app;

import android.content.Intent;
import android.graphics.Color;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.ui.PlayerView;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "NativePlayer")
public class NativePlayerPlugin extends Plugin {
  static NativePlayerPlugin instance;

  private ExoPlayer player;
  private PlayerView pview;
  private FrameLayout holder;
  private boolean full = false;
  private int rx = 0, ry = 0, rw = 400, rh = 225;
  private String curUrl = "";
  private boolean triedTs = false;

  @Override
  public void load() {
    instance = this;
  }

  /* Pantalla completa inmediata (peliculas y series) */
  @PluginMethod
  public void play(PluginCall call) {
    String url = call.getString("url");
    if (url == null) { call.reject("Falta la url"); return; }
    Intent i = new Intent(getContext(), PlayerActivity.class);
    i.putExtra("url", url);
    i.putExtra("title", call.getString("title", ""));
    getActivity().startActivity(i);
    call.resolve();
  }

  /* Vista previa pequena sobre la pagina (TV en vivo) */
  @PluginMethod
  public void preview(final PluginCall call) {
    final String url = call.getString("url");
    if (url == null) { call.reject("Falta la url"); return; }
    final int x = call.getInt("x", 0);
    final int y = call.getInt("y", 0);
    final int w = call.getInt("w", 400);
    final int h = call.getInt("h", 225);
    getActivity().runOnUiThread(() -> {
      try {
        ensurePlayer();
        rx = x; ry = y; rw = w; rh = h;
        attach();
        if (!url.equals(curUrl)) {
          curUrl = url;
          triedTs = false;
          start(url);
        } else {
          player.play();
        }
        call.resolve();
      } catch (Exception e) {
        call.reject(String.valueOf(e.getMessage()));
      }
    });
  }

  @PluginMethod
  public void place(final PluginCall call) {
    final int x = call.getInt("x", 0);
    final int y = call.getInt("y", 0);
    final int w = call.getInt("w", 400);
    final int h = call.getInt("h", 225);
    getActivity().runOnUiThread(() -> {
      rx = x; ry = y; rw = w; rh = h;
      if (holder != null && holder.getParent() != null && !full) applyLayout();
      call.resolve();
    });
  }

  @PluginMethod
  public void fullscreen(final PluginCall call) {
    final boolean on = Boolean.TRUE.equals(call.getBoolean("on", false));
    getActivity().runOnUiThread(() -> {
      setFull(on);
      call.resolve();
    });
  }

  @PluginMethod
  public void hidePreview(final PluginCall call) {
    getActivity().runOnUiThread(() -> {
      hide();
      call.resolve();
    });
  }

  boolean handleBack() {
    if (full) {
      setFull(false);
      JSObject o = new JSObject();
      o.put("on", false);
      notifyListeners("fullscreen", o);
      return true;
    }
    return false;
  }

  @Override
  protected void handleOnPause() {
    if (player != null) player.pause();
  }

  @Override
  protected void handleOnDestroy() {
    if (player != null) {
      player.release();
      player = null;
    }
    instance = null;
  }

  private void ensurePlayer() {
    if (player != null) return;
    DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
        .setUserAgent("VLC/3.0.18 LibVLC/3.0.18")
        .setAllowCrossProtocolRedirects(true)
        .setConnectTimeoutMs(15000)
        .setReadTimeoutMs(15000);
    DefaultRenderersFactory rf = new DefaultRenderersFactory(getActivity())
        .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER);
    player = new ExoPlayer.Builder(getActivity(), rf)
        .setMediaSourceFactory(new DefaultMediaSourceFactory(getActivity()).setDataSourceFactory(http))
        .build();
    player.addListener(new Player.Listener() {
      @Override
      public void onPlayerError(PlaybackException e) {
        if (!triedTs && curUrl.contains(".m3u8")) {
          triedTs = true;
          curUrl = curUrl.replace(".m3u8", ".ts");
          start(curUrl);
        } else {
          JSObject o = new JSObject();
          o.put("message", describe(e));
          notifyListeners("error", o);
        }
      }
    });
    pview = new PlayerView(getActivity());
    pview.setUseController(false);
    pview.setPlayer(player);
    holder = new FrameLayout(getActivity());
    holder.setBackgroundColor(Color.BLACK);
    holder.addView(pview, new FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    holder.setOnClickListener(v -> notifyListeners("tap", new JSObject()));
  }

  private void attach() {
    if (holder.getParent() == null) {
      ViewGroup root = getActivity().findViewById(android.R.id.content);
      root.addView(holder);
    }
    applyLayout();
  }

  private void applyLayout() {
    if (holder == null) return;
    FrameLayout.LayoutParams lp;
    if (full) {
      lp = new FrameLayout.LayoutParams(
          ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
    } else {
      lp = new FrameLayout.LayoutParams(rw, rh);
      lp.gravity = Gravity.TOP | Gravity.START;
      lp.leftMargin = rx;
      lp.topMargin = ry;
    }
    holder.setLayoutParams(lp);
  }

  private void setFull(boolean on) {
    full = on;
    applyLayout();
    View d = getActivity().getWindow().getDecorView();
    if (on) {
      d.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
          | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    } else {
      d.setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE);
    }
  }

  private void hide() {
    if (full) setFull(false);
    if (holder != null && holder.getParent() != null) {
      ((ViewGroup) holder.getParent()).removeView(holder);
    }
    if (player != null) {
      player.stop();
      player.clearMediaItems();
    }
    curUrl = "";
  }

  private void start(String url) {
    player.setMediaItem(MediaItem.fromUri(url));
    player.prepare();
    player.play();
  }

  private static String describe(PlaybackException e) {
    Throwable c = e.getCause();
    if (c instanceof HttpDataSource.InvalidResponseCodeException) {
      return "HTTP " + ((HttpDataSource.InvalidResponseCodeException) c).responseCode;
    }
    return e.getErrorCodeName();
  }
}
JAVA

cat > $PKG/PlayerActivity.java <<'JAVA'
package com.glystv.app;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.Tracks;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.datasource.HttpDataSource;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.ui.PlayerView;

public class PlayerActivity extends Activity {
  private ExoPlayer player;
  private TextView status;
  private String url;
  private boolean retried = false;
  private String firstInfo = "";
  private final Runnable clear = () -> status.setText("");

  @Override
  protected void onCreate(Bundle b) {
    super.onCreate(b);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    getWindow().getDecorView().setSystemUiVisibility(
        View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
        | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
    url = getIntent().getStringExtra("url");
    String title = getIntent().getStringExtra("title");

    FrameLayout root = new FrameLayout(this);
    root.setBackgroundColor(Color.BLACK);
    PlayerView pv = new PlayerView(this);
    root.addView(pv, new FrameLayout.LayoutParams(-1, -1));
    status = new TextView(this);
    status.setTextColor(Color.WHITE);
    status.setPadding(32, 32, 32, 32);
    status.setText(title == null ? "" : title);
    root.addView(status, new FrameLayout.LayoutParams(-2, -2, Gravity.TOP | Gravity.START));
    setContentView(root);

    DefaultHttpDataSource.Factory http = new DefaultHttpDataSource.Factory()
        .setUserAgent("VLC/3.0.18 LibVLC/3.0.18")
        .setAllowCrossProtocolRedirects(true)
        .setConnectTimeoutMs(15000)
        .setReadTimeoutMs(15000);
    DefaultRenderersFactory rf = new DefaultRenderersFactory(this)
        .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER);
    player = new ExoPlayer.Builder(this, rf)
        .setMediaSourceFactory(new DefaultMediaSourceFactory(this).setDataSourceFactory(http))
        .build();
    pv.setPlayer(player);
    player.addListener(new Player.Listener() {
      @Override
      public void onPlayerError(PlaybackException e) {
        String info = describe(e);
        if (!retried && url.contains(".m3u8")) {
          retried = true;
          firstInfo = info;
          url = url.replace(".m3u8", ".ts");
          status.setText("Probando formato .ts…");
          start();
        } else {
          status.setText(firstInfo.isEmpty() ? "Error: " + info : "Error .m3u8: " + firstInfo + " | .ts: " + info);
        }
      }
      @Override
      public void onTracksChanged(Tracks tracks) {
        if (tracks.getGroups().isEmpty()) return;
        StringBuilder sb = new StringBuilder();
        for (Tracks.Group g : tracks.getGroups()) {
          if (g.getType() == C.TRACK_TYPE_AUDIO) {
            for (int i = 0; i < g.length; i++) {
              sb.append(g.getTrackFormat(i).sampleMimeType).append(g.isTrackSupported(i) ? " ok " : " SIN-SOPORTE ");
            }
          }
        }
        status.setText("Audio: " + (sb.length() == 0 ? "sin pista" : sb.toString()));
        status.removeCallbacks(clear);
        status.postDelayed(clear, 10000);
      }
    });
    start();
  }

  private String describe(PlaybackException e) {
    Throwable c = e.getCause();
    if (c instanceof HttpDataSource.InvalidResponseCodeException) {
      return "HTTP " + ((HttpDataSource.InvalidResponseCodeException) c).responseCode;
    }
    return e.getErrorCodeName();
  }

  private void start() {
    player.setMediaItem(MediaItem.fromUri(url));
    player.prepare();
    player.play();
  }

  @Override
  protected void onDestroy() {
    if (player != null) player.release();
    super.onDestroy();
  }
}
JAVA

# Ingreso desde el telefono por QR: servidor local + formulario
mkdir -p android/app/src/main/assets
cat > $PKG/RemoteSetupPlugin.java <<'RSJAVA'
package com.glystv.app;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/* Mini servidor local: el telefono (misma red Wi-Fi) abre la direccion del QR,
   escribe servidor/usuario/clave y los envia a la TV. Los datos no salen de tu red. */
@CapacitorPlugin(name = "RemoteSetup")
public class RemoteSetupPlugin extends Plugin {
  private ServerSocket server;
  private String token = "";
  private String prefill = "";
  private int port = 0;

  @PluginMethod
  public synchronized void start(PluginCall call) {
    String s = call.getString("s", "");
    prefill = s == null ? "" : s;
    try {
      if (server == null || server.isClosed()) {
        token = String.valueOf(100000 + new SecureRandom().nextInt(900000));
        server = null;
        for (int p = 8765; p < 8785 && server == null; p++) {
          try { server = new ServerSocket(p); port = p; } catch (Exception e) { }
        }
        if (server == null) { call.reject("Sin puerto libre"); return; }
        final ServerSocket ss = server;
        Thread t = new Thread(() -> loop(ss));
        t.setDaemon(true);
        t.start();
      }
      String ip = localIp();
      if (ip == null) { call.reject("Sin red local"); return; }
      JSObject o = new JSObject();
      o.put("url", "http://" + ip + ":" + port + "/?k=" + token);
      call.resolve(o);
    } catch (Exception e) {
      call.reject(String.valueOf(e.getMessage()));
    }
  }

  @PluginMethod
  public void stop(PluginCall call) {
    closeServer();
    call.resolve();
  }

  @Override
  protected void handleOnDestroy() {
    closeServer();
  }

  private synchronized void closeServer() {
    try { if (server != null) server.close(); } catch (Exception e) { }
    server = null;
  }

  private void loop(ServerSocket ss) {
    while (!ss.isClosed()) {
      try {
        Socket c = ss.accept();
        c.setSoTimeout(5000);
        handle(c);
      } catch (Exception e) {
        if (ss.isClosed()) break;
      }
    }
  }

  private void handle(Socket c) {
    try {
      InputStream in = c.getInputStream();
      OutputStream out = c.getOutputStream();
      String req = readLine(in);
      if (req == null) return;
      int len = 0;
      String line;
      while ((line = readLine(in)) != null && line.length() > 0) {
        if (line.toLowerCase(Locale.ROOT).startsWith("content-length:")) {
          len = Integer.parseInt(line.substring(15).trim());
        }
      }
      String[] parts = req.split(" ");
      String method = parts[0];
      String target = parts.length > 1 ? parts[1] : "/";
      String path = target, query = "";
      int q = target.indexOf('?');
      if (q >= 0) { path = target.substring(0, q); query = target.substring(q + 1); }
      Map<String, String> qs = form(query);
      if (!token.equals(qs.get("k"))) {
        reply(out, 403, "text/plain; charset=utf-8", "Codigo invalido. Escanea de nuevo el QR de la TV.");
        return;
      }
      if (method.equals("POST") && path.equals("/send")) {
        if (len > 4096) { reply(out, 413, "text/plain; charset=utf-8", "Muy grande"); return; }
        byte[] body = new byte[len];
        int got = 0;
        while (got < len) {
          int r = in.read(body, got, len - got);
          if (r < 0) break;
          got += r;
        }
        Map<String, String> f = form(new String(body, 0, got, StandardCharsets.UTF_8));
        JSObject o = new JSObject();
        o.put("s", f.containsKey("s") ? f.get("s") : "");
        o.put("u", f.containsKey("u") ? f.get("u") : "");
        o.put("p", f.containsKey("p") ? f.get("p") : "");
        notifyListeners("remote", o);
        reply(out, 200, "text/plain; charset=utf-8", "OK");
      } else {
        reply(out, 200, "text/html; charset=utf-8", page());
      }
    } catch (Exception e) {
      /* peticion invalida o sin datos */
    } finally {
      try { c.close(); } catch (Exception e) { }
    }
  }

  private String page() throws Exception {
    InputStream is = getContext().getAssets().open("remote.html");
    ByteArrayOutputStream bo = new ByteArrayOutputStream();
    byte[] buf = new byte[2048];
    int n;
    while ((n = is.read(buf)) > 0) bo.write(buf, 0, n);
    is.close();
    String s = prefill.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    return bo.toString("UTF-8").replace("%%S%%", s);
  }

  private static void reply(OutputStream out, int code, String type, String body) throws Exception {
    byte[] b = body.getBytes(StandardCharsets.UTF_8);
    String h = "HTTP/1.1 " + code + " X\r\nContent-Type: " + type + "\r\nContent-Length: " + b.length
        + "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
    out.write(h.getBytes(StandardCharsets.UTF_8));
    out.write(b);
    out.flush();
  }

  private static String readLine(InputStream in) throws Exception {
    StringBuilder sb = new StringBuilder();
    int c;
    while ((c = in.read()) >= 0) {
      if (c == '\n') break;
      if (c != '\r') sb.append((char) c);
      if (sb.length() > 4096) break;
    }
    return (c < 0 && sb.length() == 0) ? null : sb.toString();
  }

  private static Map<String, String> form(String s) {
    Map<String, String> m = new HashMap<>();
    for (String kv : s.split("&")) {
      int i = kv.indexOf('=');
      if (i < 0) continue;
      try {
        m.put(URLDecoder.decode(kv.substring(0, i), "UTF-8"), URLDecoder.decode(kv.substring(i + 1), "UTF-8"));
      } catch (Exception e) { }
    }
    return m;
  }

  private static String localIp() {
    try {
      String fallback = null;
      for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
        if (!ni.isUp() || ni.isLoopback()) continue;
        for (InetAddress a : Collections.list(ni.getInetAddresses())) {
          if (a instanceof Inet4Address && a.isSiteLocalAddress()) {
            String nm = ni.getName();
            if (nm.startsWith("wlan") || nm.startsWith("eth")) return a.getHostAddress();
            if (fallback == null) fallback = a.getHostAddress();
          }
        }
      }
      return fallback;
    } catch (Exception e) {
      return null;
    }
  }
}
RSJAVA

cat > android/app/src/main/assets/remote.html <<'RSHTML'
<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>GLYSTV</title>
<style>
*{box-sizing:border-box}body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:linear-gradient(160deg,#0a1260,#2a0e5a);font-family:system-ui,sans-serif;color:#fff;padding:16px}
form{width:100%;max-width:420px;background:#0f1014;border:1px solid #343238;border-radius:18px;padding:26px 22px}
h1{margin:0 0 4px;text-align:center;font-size:28px}h1 b{color:#e6bd58}p{margin:0 0 18px;text-align:center;color:#bbb;font-size:15px}
input[type=text],input[type=url],input[type=password]{width:100%;height:52px;margin-bottom:14px;border:1px solid #34343b;border-radius:10px;padding:0 14px;font-size:17px;color:#fff;background:#090a0d}
label{display:block;margin:0 0 16px;font-size:15px;color:#ddd}
button{width:100%;height:52px;border:0;border-radius:10px;background:linear-gradient(110deg,#c9000b,#f01824);color:#fff;font-size:17px;font-weight:700}
#m{margin-top:14px;text-align:center;font-size:15px;min-height:20px}
</style></head><body>
<form id="f" autocomplete="off"><h1>GLYS<b>TV</b></h1><p>Escribe tus datos y se enviarán a la TV</p>
<input name="s" type="url" placeholder="URL del servidor (http://...)" value="%%S%%" autocapitalize="off" autocorrect="off" required>
<input name="u" type="text" placeholder="Usuario" autocapitalize="off" autocorrect="off" required>
<input name="p" id="p" type="password" placeholder="Contraseña" autocapitalize="off" required>
<label><input type="checkbox" id="sh"> Mostrar contraseña</label>
<button id="b">ENVIAR A LA TV</button><div id="m"></div></form>
<script>
var f=document.getElementById('f'),m=document.getElementById('m'),b=document.getElementById('b');
document.getElementById('sh').onchange=function(){document.getElementById('p').type=this.checked?'text':'password'};
f.onsubmit=function(e){e.preventDefault();b.disabled=true;m.textContent='Enviando…';
fetch('send'+location.search,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(new FormData(f)).toString()})
.then(function(r){if(!r.ok)throw 0;m.textContent='✔ Enviado. Mira la TV.';m.style.color='#6fe08a'})
.catch(function(){m.textContent='No se pudo enviar. Escanea el QR otra vez.';m.style.color='#ff8a8a';b.disabled=false})};
</script></body></html>
RSHTML

# Iconos y pantalla de carga a partir de logo.png (si algo falla, se usa el icono por defecto)
if [ -f logo.png ]; then
  python3 -c "import PIL" 2>/dev/null || python3 -m pip install --quiet pillow 2>/dev/null || python3 -m pip install --quiet --break-system-packages pillow 2>/dev/null || true
  python3 - <<'ICONS' || echo "No se pudieron generar los iconos; se usa el icono por defecto"
from PIL import Image, ImageDraw
import glob

src = Image.open('logo.png').convert('RGB')
w, h = src.size
g = src.convert('L')
px = g.load()

def bright(y):
    return max(px[x, y] for x in range(w)) > 60

runs, st = [], None
for y in range(h):
    b = bright(y)
    if b and st is None:
        st = y
    if not b and st is not None:
        runs.append([st, y])
        st = None
if st is not None:
    runs.append([st, h])
merged = []
for r in runs:
    if merged and r[0] - merged[-1][1] < h * 0.03:
        merged[-1][1] = r[1]
    else:
        merged.append(r)
if len(merged) >= 2:
    y0, y1 = merged[0]
else:
    y0, y1 = 0, h
band = src.crop((0, y0, w, y1))
bb = band.convert('L').point(lambda p: 255 if p > 60 else 0).getbbox()
emb = band.crop(bb) if bb else band

def icon(size, frac, circle=False):
    im = Image.new('RGB', (size, size), (0, 0, 0))
    e = emb.copy()
    k = size * frac / max(e.size)
    e = e.resize((max(1, int(e.width * k)), max(1, int(e.height * k))), Image.LANCZOS)
    im.paste(e, ((size - e.width) // 2, (size - e.height) // 2))
    if circle:
        m = Image.new('L', (size, size), 0)
        ImageDraw.Draw(m).ellipse((0, 0, size - 1, size - 1), fill=255)
        out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
        out.paste(im, (0, 0), m)
        return out
    return im

legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
fore = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
res = 'android/app/src/main/res/'
for d in legacy:
    base = res + 'mipmap-' + d + '/'
    if glob.glob(base):
        icon(legacy[d], 0.78).save(base + 'ic_launcher.png')
        icon(legacy[d], 0.70, True).save(base + 'ic_launcher_round.png')
        icon(fore[d], 0.50).save(base + 'ic_launcher_foreground.png')

for p in glob.glob(res + 'drawable*/splash.png'):
    sz = Image.open(p).size
    im = Image.new('RGB', sz, (0, 0, 0))
    e = emb.copy()
    k = min(sz) * 0.34 / max(e.size)
    e = e.resize((max(1, int(e.width * k)), max(1, int(e.height * k))), Image.LANCZOS)
    im.paste(e, ((sz[0] - e.width) // 2, (sz[1] - e.height) // 2))
    im.save(p)
print('iconos ok', emb.size)
ICONS
  if [ -f icon.png ]; then
    python3 - <<'ICON2' || echo "No se pudo aplicar icon.png; se usa el icono anterior"
from PIL import Image, ImageDraw
import os
m = Image.open('icon.png').convert('RGB')
e = m.getpixel((2, 2))
legacy = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}
fore = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432}
res = 'android/app/src/main/res/'
for d in legacy:
    base = res + 'mipmap-' + d + '/'
    if not os.path.isdir(base):
        continue
    s = legacy[d]
    m.resize((s, s), Image.LANCZOS).save(base + 'ic_launcher.png')
    r = m.resize((s, s), Image.LANCZOS)
    mk = Image.new('L', (s, s), 0)
    ImageDraw.Draw(mk).ellipse((0, 0, s - 1, s - 1), fill=255)
    o = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    o.paste(r, (0, 0), mk)
    o.save(base + 'ic_launcher_round.png')
    f = fore[d]
    c = Image.new('RGB', (f, f), e)
    t = m.resize((int(f * 0.78), int(f * 0.78)), Image.LANCZOS)
    c.paste(t, ((f - t.width) // 2, (f - t.height) // 2))
    c.save(base + 'ic_launcher_foreground.png')
os.makedirs(res + 'values', exist_ok=True)
open(res + 'values/ic_launcher_background.xml', 'w').write(
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">#%02X%02X%02X</color>\n</resources>\n' % e)
print('icon.png aplicado')
ICON2
  fi
  sed -i 's/#FFFFFF/#000000/I' android/app/src/main/res/values/ic_launcher_background.xml 2>/dev/null || true
fi

# 3) Permisos, actividad del reproductor y librería ExoPlayer
sed -i 's#<application#<application android:usesCleartextTraffic="true"#' $MAN
sed -i 's#</application>#    <activity android:name=".PlayerActivity" android:exported="false" android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize" android:theme="@android:style/Theme.Black.NoTitleBar.Fullscreen" />\n    </application>#' $MAN
sed -i '/^dependencies {/a\    implementation "androidx.media3:media3-exoplayer:1.4.1"\n    implementation "androidx.media3:media3-exoplayer-hls:1.4.1"\n    implementation "androidx.media3:media3-ui:1.4.1"\n    implementation "org.jellyfin.media3:media3-ffmpeg-decoder:1.4.1+1"' android/app/build.gradle

# 3b) Hacer que la app aparezca en el launcher de Android TV (banner + LEANBACK_LAUNCHER)
python3 patch_tv.py .

# 4) Compilar
npx cap sync android
cd android
chmod +x gradlew
./gradlew assembleDebug --no-daemon || {
  echo "Reintentando sin el decodificador FFmpeg..."
  sed -i '/media3-ffmpeg-decoder/d' app/build.gradle
  ./gradlew assembleDebug --no-daemon
}
