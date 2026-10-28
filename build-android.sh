#!/usr/bin/env bash
set -euo pipefail

# 1) Web de la app
rm -rf www android
mkdir www
cp index.html www/
[ -f logo.png ] && cp logo.png www/

# 2) Proyecto Android
npx cap add android
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
    super.onCreate(savedInstanceState);
  }
}
JAVA

cat > $PKG/NativePlayerPlugin.java <<'JAVA'
package com.glystv.app;

import android.content.Intent;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "NativePlayer")
public class NativePlayerPlugin extends Plugin {
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

# 3) Permisos, actividad del reproductor y librería ExoPlayer
sed -i 's#<application#<application android:usesCleartextTraffic="true"#' $MAN
sed -i 's#</application>#    <activity android:name=".PlayerActivity" android:exported="false" android:configChanges="orientation|screenSize|keyboardHidden|screenLayout|smallestScreenSize" android:theme="@android:style/Theme.Black.NoTitleBar.Fullscreen" />\n    </application>#' $MAN
sed -i '/^dependencies {/a\    implementation "androidx.media3:media3-exoplayer:1.4.1"\n    implementation "androidx.media3:media3-exoplayer-hls:1.4.1"\n    implementation "androidx.media3:media3-ui:1.4.1"\n    implementation "org.jellyfin.media3:media3-ffmpeg-decoder:1.4.1+1"' android/app/build.gradle

# 4) Compilar
npx cap sync android
cd android
chmod +x gradlew
./gradlew assembleDebug --no-daemon || {
  echo "Reintentando sin el decodificador FFmpeg..."
  sed -i '/media3-ffmpeg-decoder/d' app/build.gradle
  ./gradlew assembleDebug --no-daemon
}
