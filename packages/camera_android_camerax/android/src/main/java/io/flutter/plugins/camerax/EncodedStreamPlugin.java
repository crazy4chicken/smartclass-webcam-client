// Part of the vendored `camera_android_camerax` fork (see VENDORED.md).
//
// The Android native half of the encoded-stream seam (ADR 0002 §四): a MethodChannel to open/close
// the pipeline and to enumerate encoders, plus an EventChannel that pushes one compressed access
// unit per event. Binding follows ADR 0002 §九 (mechanism 4, "native self-bind"): this class builds
// its own VideoCapture<EncodedStreamVideoOutput> and binds it to the LifecycleOwner CameraX already
// uses. CameraX appends use cases for the same LifecycleOwner, so the already-bound Preview /
// ImageCapture are left alone and unbindAll() is never called.

package io.flutter.plugins.camerax;

import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.Range;
import android.util.Size;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.camera2.interop.Camera2CameraInfo;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import androidx.camera.core.resolutionselector.ResolutionStrategy;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.video.VideoCapture;
import androidx.lifecycle.LifecycleOwner;
import com.google.common.util.concurrent.ListenableFuture;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Owns the encoded-stream pipeline: {@code VideoCapture} + {@link EncodedStreamVideoOutput} +
 * {@code MediaCodec}, and the two Flutter channels that expose it.
 *
 * <p>Channel names and payload shapes are frozen by ADR 0002 §四 and must not change here.
 */
public final class EncodedStreamPlugin
    implements MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  private static final String TAG = "EncodedStreamPlugin";

  private static final String METHOD_CHANNEL = "smartclass/encoded_stream";
  private static final String EVENT_CHANNEL = "smartclass/encoded_stream/packets";

  private static final String HEVC_MIME = "video/hevc";
  private static final String AVC_MIME = "video/avc";

  /** Bound on a {@link ProcessCameraProvider} future and on main-thread round trips. */
  private static final long WAIT_TIMEOUT_MS = 10_000L;

  @Nullable private static volatile EncodedStreamPlugin instance;

  @NonNull private final ProxyApiRegistrar registrar;
  @NonNull private final Handler mainHandler = new Handler(Looper.getMainLooper());
  @NonNull private final MethodChannel methodChannel;
  @NonNull private final EventChannel eventChannel;

  /**
   * CameraX bind/unbind must happen on the main thread, and {@link EncodedStreamVideoOutput#close()}
   * blocks until the encoder tail is flushed, so no channel call may run that work on the main
   * thread it was delivered on.
   */
  @NonNull private final ExecutorService worker;

  @NonNull private final Object lock = new Object();

  @Nullable private EventChannel.EventSink eventSink;
  @Nullable private EncodedStreamVideoOutput output;
  @Nullable private VideoCapture<EncodedStreamVideoOutput> videoCapture;
  @Nullable private ProcessCameraProvider cameraProvider;

  private EncodedStreamPlugin(
      @NonNull BinaryMessenger messenger, @NonNull ProxyApiRegistrar registrar) {
    this.registrar = registrar;
    this.methodChannel = new MethodChannel(messenger, METHOD_CHANNEL);
    this.eventChannel = new EventChannel(messenger, EVENT_CHANNEL);
    this.worker =
        Executors.newSingleThreadExecutor(
            runnable -> new Thread(runnable, "EncodedStreamPluginWorker"));
    methodChannel.setMethodCallHandler(this);
    eventChannel.setStreamHandler(this);
  }

  /**
   * Registers the encoded-stream channels on {@code messenger}. Called from
   * {@code CameraAndroidCameraxPlugin.onAttachedToEngine}; a previous registration (a re-attach) is
   * torn down first so channels are never double-registered.
   */
  public static void register(
      @NonNull BinaryMessenger messenger, @NonNull ProxyApiRegistrar registrar) {
    unregister();
    instance = new EncodedStreamPlugin(messenger, registrar);
  }

  /** Removes the channel handlers and releases any pipeline still open. Idempotent. */
  public static void unregister() {
    final EncodedStreamPlugin current = instance;
    instance = null;
    if (current != null) {
      current.dispose();
    }
  }

  private void dispose() {
    methodChannel.setMethodCallHandler(null);
    eventChannel.setStreamHandler(null);
    synchronized (lock) {
      eventSink = null;
    }
    // Release on the worker: close() may block for the EOS timeout, which must never happen on the
    // main thread. shutdown() lets this queued task finish without accepting new ones.
    worker.execute(this::releaseResources);
    worker.shutdown();
  }

  // ---------------------------------------------------------------- MethodChannel

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    switch (call.method) {
      case "open":
        worker.execute(() -> open(call.arguments, result));
        return;
      case "close":
        worker.execute(() -> close(result));
        return;
      case "encoders":
        worker.execute(() -> encoders(result));
        return;
      default:
        result.notImplemented();
    }
  }

  /** Opens the pipeline: build the format, create the output, bind our own {@code VideoCapture}. */
  private void open(@Nullable Object rawArgs, @NonNull MethodChannel.Result result) {
    EncodedStreamVideoOutput newOutput = null;
    VideoCapture<EncodedStreamVideoOutput> newCapture = null;
    ProcessCameraProvider provider = null;
    try {
      final Map<String, Object> args = asMap(rawArgs);
      final int cameraId = intArg(args, "cameraId");
      final int width = intArg(args, "width");
      final int height = intArg(args, "height");
      final int fps = intArg(args, "fps");
      final int quality = intArg(args, "quality");
      final long generation = longArg(args, "sessionGeneration");
      final String codec = stringArg(args, "codec");

      // A previous run that was never closed would otherwise leak its codec and stay bound.
      releaseResources();

      final MediaFormat format = buildMediaFormat(codec, width, height, fps, quality);
      newOutput = new EncodedStreamVideoOutput(format, generation, this::onPacket);

      provider = getCameraProvider();
      final CameraSelector selector = resolveCameraSelector(provider, cameraId);
      newCapture = buildVideoCapture(newOutput, width, height, fps);

      final ProcessCameraProvider boundTo = provider;
      final VideoCapture<EncodedStreamVideoOutput> toBind = newCapture;
      onMain(() -> bindToLifecycle(boundTo, selector, toBind), "bindToLifecycle");

      synchronized (lock) {
        output = newOutput;
        videoCapture = newCapture;
        cameraProvider = provider;
      }
      Log.i(TAG, "open: " + width + "x" + height + "@" + fps + " via " + newOutput.getEncoderName());
      resolve(result, null);
    } catch (Exception e) {
      // Never leave a half-open pipeline: close the output (which waits for the tail) and unbind.
      if (newOutput != null) {
        newOutput.close();
      }
      if (provider != null && newCapture != null) {
        final ProcessCameraProvider boundTo = provider;
        final VideoCapture<EncodedStreamVideoOutput> toUnbind = newCapture;
        try {
          onMain(() -> unbindQuietly(boundTo, toUnbind), "unbind");
        } catch (Exception ignored) {
          // The open failure below is the one that matters.
        }
      }
      fail(result, "open_failed", "open failed: " + describe(e));
    }
  }

  /**
   * Closes the pipeline. Resolves only after {@link EncodedStreamVideoOutput#close()} returned,
   * i.e. after the encoder tail was flushed and delivered (that call is itself bounded at 5 s).
   */
  private void close(@NonNull MethodChannel.Result result) {
    try {
      releaseResources();
      resolve(result, null);
    } catch (Exception e) {
      fail(result, "close_failed", "close failed: " + describe(e));
    }
  }

  /** Closes the output, waits for the tail, then unbinds our use case only. */
  private void releaseResources() {
    final EncodedStreamVideoOutput outputToClose;
    final VideoCapture<EncodedStreamVideoOutput> captureToUnbind;
    final ProcessCameraProvider providerToUnbind;
    synchronized (lock) {
      outputToClose = output;
      captureToUnbind = videoCapture;
      providerToUnbind = cameraProvider;
      output = null;
      videoCapture = null;
      cameraProvider = null;
    }
    if (outputToClose != null) {
      outputToClose.close();
    }
    if (providerToUnbind != null && captureToUnbind != null) {
      onMain(() -> unbindQuietly(providerToUnbind, captureToUnbind), "unbind");
    }
  }

  /** Lists every encoder that can produce {@code video/hevc} or {@code video/avc}. */
  private void encoders(@NonNull MethodChannel.Result result) {
    try {
      final List<Map<String, Object>> encoders = new ArrayList<>();
      for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos()) {
        if (!info.isEncoder()) {
          continue;
        }
        final boolean hardware = isHardware(info);
        for (String type : info.getSupportedTypes()) {
          final String codec;
          if (HEVC_MIME.equalsIgnoreCase(type)) {
            codec = "h265";
          } else if (AVC_MIME.equalsIgnoreCase(type)) {
            codec = "h264";
          } else {
            continue;
          }
          final Map<String, Object> entry = new HashMap<>();
          entry.put("codec", codec);
          entry.put("name", info.getName());
          entry.put("hardware", hardware);
          encoders.add(entry);
        }
      }
      final Map<String, Object> payload = new HashMap<>();
      payload.put("encoders", encoders);
      resolve(result, payload);
    } catch (Exception e) {
      fail(result, "encoders_failed", "encoders failed: " + describe(e));
    }
  }

  // ---------------------------------------------------------------- EventChannel

  @Override
  public void onListen(@Nullable Object arguments, @NonNull EventChannel.EventSink events) {
    synchronized (lock) {
      eventSink = events;
    }
  }

  @Override
  public void onCancel(@Nullable Object arguments) {
    synchronized (lock) {
      eventSink = null;
    }
  }

  /** One encoded access unit. Always delivered on the main thread: channels require it. */
  private void onPacket(
      @NonNull byte[] bytes, int pictures, long ptsUs, boolean eos, long generation) {
    final Map<String, Object> event = new HashMap<>();
    event.put("bytes", bytes);
    event.put("pictures", pictures);
    event.put("ptsUs", ptsUs);
    event.put("generation", generation);
    event.put("eos", eos);
    mainHandler.post(
        () -> {
          final EventChannel.EventSink sink;
          synchronized (lock) {
            sink = eventSink;
          }
          if (sink != null) {
            sink.success(event);
          }
        });
  }

  // ---------------------------------------------------------------- CameraX wiring

  @NonNull
  private ProcessCameraProvider getCameraProvider() {
    // CameraX wants getInstance() called on the main thread; the blocking wait happens here, on the
    // worker, so a slow CameraX init cannot stall the main thread or deadlock against it.
    final ListenableFuture<ProcessCameraProvider> future =
        onMain(() -> ProcessCameraProvider.getInstance(registrar.getContext()), "getInstance");
    if (future == null) {
      throw new IllegalStateException("ProcessCameraProvider.getInstance returned no future.");
    }
    try {
      return future.get(WAIT_TIMEOUT_MS, TimeUnit.MILLISECONDS);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException("Interrupted waiting for ProcessCameraProvider.", e);
    } catch (Exception e) {
      throw new IllegalStateException("Could not obtain ProcessCameraProvider.", e);
    }
  }

  @NonNull
  private static CameraSelector resolveCameraSelector(
      @NonNull ProcessCameraProvider provider, int cameraId) {
    final String wanted = String.valueOf(cameraId);
    for (CameraInfo cameraInfo : provider.getAvailableCameraInfos()) {
      if (wanted.equals(Camera2CameraInfo.from(cameraInfo).getCameraId())) {
        return cameraInfo.getCameraSelector();
      }
    }
    throw new IllegalArgumentException(
        "No CameraX camera info matches cameraId " + wanted + ".");
  }

  /**
   * ADR 0002 §10.5: the resolution selector is the only thing allowed to decide the geometry
   * (the encoder is configured from the {@link MediaFormat} width/height, so a CameraX-chosen size
   * that differs would produce a broken picture), the frame rate must be pinned to {@code fps}, and
   * {@code setCustomOrderedResolutions} must stay off (it collides with the quality path).
   */
  @NonNull
  private static VideoCapture<EncodedStreamVideoOutput> buildVideoCapture(
      @NonNull EncodedStreamVideoOutput output, int width, int height, int fps) {
    final ResolutionSelector resolutionSelector =
        new ResolutionSelector.Builder()
            .setResolutionStrategy(
                new ResolutionStrategy(
                    new Size(width, height),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
            .build();
    return new VideoCapture.Builder<>(output)
        .setResolutionSelector(resolutionSelector)
        .setTargetFrameRate(new Range<>(fps, fps))
        .build();
  }

  @Nullable
  private Void bindToLifecycle(
      @NonNull ProcessCameraProvider provider,
      @NonNull CameraSelector selector,
      @NonNull VideoCapture<EncodedStreamVideoOutput> capture) {
    final LifecycleOwner lifecycleOwner = registrar.getLifecycleOwner();
    if (lifecycleOwner == null) {
      throw new IllegalStateException(
          "No LifecycleOwner available; the Activity has not been attached yet.");
    }
    // A separate bind of only our use case: CameraX appends to the same LifecycleOwner, so the
    // already-bound Preview/ImageCapture survive (ADR 0002 §九.3).
    provider.bindToLifecycle(lifecycleOwner, selector, capture);
    return null;
  }

  @Nullable
  private static Void unbindQuietly(
      @NonNull ProcessCameraProvider provider,
      @NonNull VideoCapture<EncodedStreamVideoOutput> capture) {
    try {
      provider.unbind(capture);
    } catch (Exception e) {
      Log.w(TAG, "unbind failed: " + e);
    }
    return null;
  }

  // ---------------------------------------------------------------- MediaFormat

  /**
   * Builds the encoder format.
   *
   * <p>{@code KEY_BIT_RATE} has no field in the frozen protocol — {@code quality} (0-100) is the
   * only knob — so it is derived from a documented, monotone bits-per-pixel mapping:
   * {@code bpp = 0.04 + 0.08 * quality/100} (4.6 Mbps .. 14 Mbps at 1080p60), times
   * {@code width * height * fps}. That is a knob, not a measured budget: it only has to move
   * monotonically with {@code quality} until Task 6 measures the real sustained rate on the target
   * device.
   *
   * <p>{@code KEY_COLOR_FORMAT} is deliberately left unset (the input is a Surface: MediaCodec
   * owns the color format) and no bitrate mode is set (leave the encoder default until measured).
   */
  @NonNull
  private static MediaFormat buildMediaFormat(
      @NonNull String codec, int width, int height, int fps, int quality) {
    final String mime;
    if ("h265".equals(codec)) {
      mime = HEVC_MIME;
    } else if ("h264".equals(codec)) {
      mime = AVC_MIME;
    } else {
      throw new IllegalArgumentException("Unsupported codec: " + codec + " (want h265 or h264).");
    }
    if (width <= 0 || height <= 0 || fps <= 0) {
      throw new IllegalArgumentException(
          "width/height/fps must be positive, got " + width + "x" + height + "@" + fps + ".");
    }
    final int clamped = Math.max(0, Math.min(100, quality));
    final double bitsPerPixel = 0.04d + 0.08d * (clamped / 100d);
    final long bitRate = (long) (bitsPerPixel * width * height * fps);

    final MediaFormat format = new MediaFormat();
    format.setString(MediaFormat.KEY_MIME, mime);
    format.setInteger(MediaFormat.KEY_WIDTH, width);
    format.setInteger(MediaFormat.KEY_HEIGHT, height);
    format.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
    format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
    format.setInteger(MediaFormat.KEY_BIT_RATE, (int) Math.min(bitRate, Integer.MAX_VALUE));
    return format;
  }

  /** Mirrors {@code EncodedStreamVideoOutput.isHardware} so both sides report the same thing. */
  private static boolean isHardware(@NonNull MediaCodecInfo info) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      return info.isHardwareAccelerated();
    }
    final String name = info.getName().toLowerCase(Locale.US);
    return !(name.startsWith("omx.google.") || name.startsWith("c2.android."));
  }

  // ---------------------------------------------------------------- plumbing

  /** Runs {@code action} on the main thread and waits for it; used for CameraX calls. */
  @Nullable
  private <T> T onMain(@NonNull MainThreadAction<T> action, @NonNull String what) {
    if (Looper.myLooper() == Looper.getMainLooper()) {
      try {
        return action.run();
      } catch (Exception e) {
        throw asRuntime(what, e);
      }
    }
    final AtomicReference<T> value = new AtomicReference<>();
    final AtomicReference<Exception> failure = new AtomicReference<>();
    final CountDownLatch latch = new CountDownLatch(1);
    mainHandler.post(
        () -> {
          try {
            value.set(action.run());
          } catch (Exception e) {
            failure.set(e);
          } finally {
            latch.countDown();
          }
        });
    try {
      if (!latch.await(WAIT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
        throw new IllegalStateException(
            what + " did not run on the main thread within " + WAIT_TIMEOUT_MS + " ms.");
      }
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
      throw new IllegalStateException(what + " was interrupted.", e);
    }
    if (failure.get() != null) {
      throw asRuntime(what, failure.get());
    }
    return value.get();
  }

  private interface MainThreadAction<T> {
    @Nullable T run() throws Exception;
  }

  @NonNull
  private static RuntimeException asRuntime(@NonNull String what, @NonNull Exception e) {
    if (e instanceof RuntimeException) {
      return (RuntimeException) e;
    }
    return new IllegalStateException(what + " failed: " + e.getMessage(), e);
  }

  private void resolve(@NonNull MethodChannel.Result result, @Nullable Object value) {
    if (Looper.myLooper() == Looper.getMainLooper()) {
      result.success(value);
    } else {
      mainHandler.post(() -> result.success(value));
    }
  }

  private void fail(
      @NonNull MethodChannel.Result result, @NonNull String code, @NonNull String message) {
    Log.e(TAG, code + ": " + message);
    if (Looper.myLooper() == Looper.getMainLooper()) {
      result.error(code, message, null);
    } else {
      mainHandler.post(() -> result.error(code, message, null));
    }
  }

  private static String describe(@NonNull Throwable t) {
    final String message = t.getMessage();
    return t.getClass().getSimpleName() + (message == null ? "" : ": " + message);
  }

  @NonNull
  @SuppressWarnings("unchecked")
  private static Map<String, Object> asMap(@Nullable Object rawArgs) {
    if (rawArgs instanceof Map) {
      return (Map<String, Object>) rawArgs;
    }
    throw new IllegalArgumentException("open expects a Map of arguments, got: " + rawArgs);
  }

  private static int intArg(@NonNull Map<String, Object> args, @NonNull String key) {
    final Object value = args.get(key);
    if (value instanceof Number) {
      return ((Number) value).intValue();
    }
    throw new IllegalArgumentException("Missing or non-numeric argument: " + key);
  }

  private static long longArg(@NonNull Map<String, Object> args, @NonNull String key) {
    final Object value = args.get(key);
    if (value instanceof Number) {
      return ((Number) value).longValue();
    }
    throw new IllegalArgumentException("Missing or non-numeric argument: " + key);
  }

  @NonNull
  private static String stringArg(@NonNull Map<String, Object> args, @NonNull String key) {
    final Object value = args.get(key);
    if (value instanceof String) {
      return (String) value;
    }
    throw new IllegalArgumentException("Missing or non-string argument: " + key);
  }
}
