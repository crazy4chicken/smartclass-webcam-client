// Part of the vendored `camera_android_camerax` fork (see VENDORED.md).
//
// A custom androidx.camera.video.VideoOutput that feeds CameraX's camera surface straight into a
// MediaCodec encoder and reports each compressed access unit to a packet callback. No raw frame
// crosses into Dart and nothing touches disk.

package io.flutter.plugins.camerax;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.DynamicRange;
import androidx.camera.core.SurfaceRequest;
import androidx.camera.core.impl.Observable;
import androidx.camera.video.MediaSpec;
import androidx.camera.video.Quality;
import androidx.camera.video.VideoCapabilities;
import androidx.camera.video.VideoOutput;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;
import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * A {@link VideoOutput} that encodes the CameraX camera stream in-process with {@link MediaCodec}
 * and hands every compressed access unit to a {@link PacketCallback}.
 *
 * <p>The caller supplies the fully-populated {@link MediaFormat} (MIME, width, height, frame rate,
 * {@code KEY_I_FRAME_INTERVAL}, bit rate). This class only selects a hardware encoder, wires the
 * codec's input surface to CameraX, and forwards output buffers. It knows nothing about Flutter.
 *
 * <p>Encoder selection deliberately refuses to fall back to a software ({@code c2.android.*})
 * encoder: a software encoder cannot hold 1080p60, and a silent fallback is the exact failure this
 * feature exists to remove.
 */
public final class EncodedStreamVideoOutput implements VideoOutput {

  /** Receives one compressed access unit, or a zero-picture config/EOS packet. */
  @FunctionalInterface
  public interface PacketCallback {
    /**
     * @param bytes the compressed bytes; empty for an EOS-only packet
     * @param pictures whole pictures in this buffer; a codec-config or empty buffer reports 0
     * @param ptsUs presentation timestamp in microseconds, as reported by {@link MediaCodec}
     * @param eos whether this packet carries {@code BUFFER_FLAG_END_OF_STREAM}
     * @param generation the session generation this output was opened with
     */
    void onPacket(@NonNull byte[] bytes, int pictures, long ptsUs, boolean eos, long generation);
  }

  private static final long EOS_TIMEOUT_MS = 5_000L;
  private static final String HEVC_MIME = "video/hevc";
  private static final String AVC_MIME = "video/avc";

  /**
   * The capabilities this output reports to {@code VideoCapture}: SDR only, no {@link Quality}.
   *
   * <p>The dynamic range is the load-bearing half. {@code VideoCapture} intersects these with the
   * other bound use cases, and the {@link VideoOutput} default ({@link VideoCapabilities#EMPTY})
   * reports an empty set, so there is nothing left to intersect. The quality list is deliberately
   * empty so
   * that {@code VideoCapture} skips its quality-driven resolution table (it logs "Can't find any
   * supported quality on the device" and returns): this encoder takes its geometry from the
   * {@link android.media.MediaFormat} it was constructed with, so the only thing allowed to pick a
   * resolution is the {@code ResolutionSelector} the caller sets on the {@code VideoCapture.Builder}.
   */
  private static final VideoCapabilities SDR_ONLY_CAPABILITIES =
      new VideoCapabilities() {
        @NonNull
        @Override
        public Set<DynamicRange> getSupportedDynamicRanges() {
          return Collections.singleton(DynamicRange.SDR);
        }

        @NonNull
        @Override
        public List<Quality> getSupportedQualities(@NonNull DynamicRange dynamicRange) {
          return Collections.emptyList();
        }

        @Override
        public boolean isQualitySupported(
            @NonNull Quality quality, @NonNull DynamicRange dynamicRange) {
          return false;
        }
      };

  @NonNull private final MediaFormat format;
  @NonNull private final String mimeType;
  @NonNull private final String encoderName;
  private final long generation;
  @NonNull private final PacketCallback packetCallback;

  // The single live pipeline. onSurfaceRequested may run more than once (a re-bind, a resolution
  // change); each call replaces this and tears the previous one down.
  @Nullable private volatile Pipeline current;

  // `closing` is set as soon as close() starts (the EOS packet still has to be delivered).
  private volatile boolean closing;

  /**
   * Selects a hardware encoder for the format's MIME type.
   *
   * @throws IllegalArgumentException if the format has no MIME type or an unsupported one
   * @throws IllegalStateException if no hardware encoder exists (never silently falls back)
   */
  public EncodedStreamVideoOutput(
      @NonNull MediaFormat format, long generation, @NonNull PacketCallback packetCallback) {
    final String mime = format.getString(MediaFormat.KEY_MIME);
    if (mime == null) {
      throw new IllegalArgumentException("MediaFormat is missing KEY_MIME.");
    }
    this.format = format;
    this.mimeType = mime;
    this.generation = generation;
    this.packetCallback = packetCallback;
    this.encoderName = selectHardwareEncoder(mime);
  }

  /** The codec name actually selected; this is the encoder identity reported to Dart. */
  @NonNull
  public String getEncoderName() {
    return encoderName;
  }

  // getStreamInfo() is deliberately NOT overridden.
  //
  // CameraX 1.6.2 closed StreamInfo off: StreamInfo.of(...), STREAM_ID_ANY and even the
  // StreamState enum are package-private, so no type outside androidx.camera.video can build one;
  // that is why the hand-written override this comment replaces did not compile. The default returns
  // StreamInfo.ALWAYS_ACTIVE_OBSERVABLE, i.e. StreamInfo.of(STREAM_ID_ANY, StreamState.ACTIVE):
  // exactly the "this output always consumes frames" state that override was trying to declare.
  // (Read off camera-video-1.6.2's classes.jar.) Do not reinstate an override here.

  /**
   * A non-null {@link MediaSpec}. {@code VideoCapture} throws {@code IllegalArgumentException}
   * ("MediaSpec can't be null") from {@code onMergeConfig()} and runs the value through
   * {@code Objects.requireNonNull} on stream-spec updates, so the interface default (null) is not
   * survivable. The content stays at the default: geometry, frame rate and bit rate come from the
   * caller's {@link android.media.MediaFormat}, not from CameraX quality negotiation.
   */
  @NonNull
  @Override
  public Observable<MediaSpec> getMediaSpec() {
    return FixedObservable.of(MediaSpec.builder().build());
  }

  @NonNull
  @Override
  public VideoCapabilities getMediaCapabilities(@NonNull CameraInfo cameraInfo, int sessionType) {
    return SDR_ONLY_CAPABILITIES;
  }

  @Override
  public void onSurfaceRequested(@NonNull SurfaceRequest request) {
    // CameraX can request a surface more than once for the same output (a re-bind, a resolution
    // change). Tear the previous pipeline down first, through the same serialised path as close(),
    // so its codec and HandlerThread do not leak and keep running against a surface nobody feeds.
    final Pipeline previous = current;
    current = null;
    if (previous != null) {
      previous.release();
    }

    final Pipeline pipeline = new Pipeline();
    try {
      pipeline.handlerThread = new HandlerThread("EncodedStreamVideoOutput");
      pipeline.handlerThread.start();
      pipeline.handler = new Handler(pipeline.handlerThread.getLooper());

      final MediaCodec codec = MediaCodec.createByCodecName(encoderName);
      pipeline.codec = codec;
      // Async mode requires the callback to be set before configure().
      codec.setCallback(new EncoderCallback(pipeline), pipeline.handler);
      codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
      pipeline.inputSurface = codec.createInputSurface();
      codec.start();
    } catch (Exception e) {
      pipeline.release();
      request.willNotProvideSurface();
      return;
    }

    current = pipeline;

    // Capture the handler in a local so the executor never dereferences a field that teardown
    // could have cleared. If it is null we cannot serve the surface at all.
    final Handler handlerForSurface = pipeline.handler;
    if (handlerForSurface == null) {
      pipeline.release();
      current = null;
      request.willNotProvideSurface();
      return;
    }

    request.provideSurface(
        pipeline.inputSurface,
        command -> handlerForSurface.post(command),
        result -> {
          if (result.getResultCode() != SurfaceRequest.Result.RESULT_SURFACE_USED_SUCCESSFULLY) {
            // The camera no longer writes to this surface; nothing more will be encoded.
            pipeline.release();
          }
        });
  }

  /**
   * Signals end of stream, waits (bounded, {@value #EOS_TIMEOUT_MS} ms) for the EOS output buffer,
   * then tears the codec down on its own handler thread. Idempotent. The caller's {@code close()}
   * resolving means the EOS packet was already delivered.
   */
  public void close() {
    if (closing) {
      return;
    }
    closing = true;

    final Pipeline pipeline = current;
    if (pipeline != null) {
      pipeline.signalEndOfStream();
      try {
        pipeline.eosLatch.await(EOS_TIMEOUT_MS, TimeUnit.MILLISECONDS);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }

    // The await above delivered the tail (or the bounded timeout expired): close() resolving means
    // the EOS packet was already handed to the PacketCallback. Teardown is posted onto the codec's
    // own handler thread, so it can never interleave with a MediaCodec callback. close() may return
    // before that posted teardown has run; a new recording run constructs a new instance of this
    // class, so nothing else can observe this instance's delayed teardown.
    if (pipeline != null) {
      pipeline.release();
    }
    releaseQuietly();
  }

  private void releaseQuietly() {
    final Pipeline pipeline = current;
    if (pipeline != null) {
      pipeline.release();
    }
  }

  /**
   * One codec + input surface + handler thread. All teardown is serialised onto {@link #handler},
   * the same thread that runs {@link EncoderCallback}, so {@code stop()}/{@code release()} can
   * never interleave with {@code releaseOutputBuffer()}. {@link #tornDown} makes teardown
   * idempotent, so the two callers of release (close() and the SurfaceRequest result callback)
   * cannot both proceed.
   */
  private static final class Pipeline {
    @Nullable HandlerThread handlerThread;
    @Nullable Handler handler;
    @Nullable MediaCodec codec;
    @Nullable Surface inputSurface;
    final CountDownLatch eosLatch = new CountDownLatch(1);
    final AtomicBoolean tornDown = new AtomicBoolean(false);
    // Set before the posted teardown runs; the callback checks it to stop delivering packets.
    volatile boolean released;

    void signalEndOfStream() {
      final MediaCodec c = codec;
      if (c != null) {
        try {
          c.signalEndOfInputStream();
        } catch (IllegalStateException ignored) {
          // Not started, or input is not a surface; nothing to flush.
        }
      }
    }

    void release() {
      if (!tornDown.compareAndSet(false, true)) {
        return;
      }
      released = true;
      final Handler h = handler;
      final Runnable teardown = this::tearDown;
      if (h == null || !h.post(teardown)) {
        // No handler (never created, or its thread is already gone): release inline. The guard
        // above still ensures this runs at most once.
        teardown.run();
      }
    }

    private void tearDown() {
      final MediaCodec c = codec;
      if (c != null) {
        try {
          c.stop();
        } catch (Exception ignored) {
          // Already stopped.
        }
        try {
          c.release();
        } catch (Exception ignored) {
          // Already released.
        }
      }
      final Surface s = inputSurface;
      if (s != null) {
        s.release();
      }
      final HandlerThread t = handlerThread;
      if (t != null) {
        t.quitSafely();
      }
    }
  }

  /**
   * The smallest possible {@link Observable}: one value, handed to every observer on registration.
   * CameraX's own {@code ConstantObservable} behaves the same but sits in an
   * {@code @RestrictTo(LIBRARY_GROUP)} package; this keeps the fork off it.
   */
  private static final class FixedObservable<T> implements Observable<T> {
    @NonNull private final T value;

    static <T> Observable<T> of(@NonNull T value) {
      return new FixedObservable<>(value);
    }

    private FixedObservable(@NonNull T value) {
      this.value = value;
    }

    @NonNull
    @Override
    public ListenableFuture<T> fetchData() {
      return Futures.immediateFuture(value);
    }

    @Override
    public void addObserver(
        @NonNull Executor executor, @NonNull Observable.Observer<? super T> observer) {
      executor.execute(() -> observer.onNewData(value));
    }

    @Override
    public void removeObserver(@NonNull Observable.Observer<? super T> observer) {
      // A constant value has nothing to unregister.
    }
  }

  private final class EncoderCallback extends MediaCodec.Callback {
    private final Pipeline pipeline;

    EncoderCallback(Pipeline pipeline) {
      this.pipeline = pipeline;
    }

    @Override
    public void onInputBufferAvailable(@NonNull MediaCodec codec, int index) {
      // Surface input: MediaCodec fills the input buffers; nothing to do here.
    }

    @Override
    public void onOutputBufferAvailable(
        @NonNull MediaCodec codec, int index, @NonNull MediaCodec.BufferInfo info) {
      try {
        final boolean codecConfig = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
        final boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;

        byte[] bytes = new byte[0];
        final ByteBuffer buffer = codec.getOutputBuffer(index);
        if (buffer != null && info.size > 0) {
          buffer.position(info.offset);
          buffer.limit(info.offset + info.size);
          bytes = new byte[info.size];
          buffer.get(bytes);
        }

        // A codec-config buffer (VPS/SPS/PPS) is not a picture: report 0 and let the downstream
        // AnnexBSplitter attach it to the next picture. Any other non-empty buffer is one access
        // unit = one picture. Do not merge anything here.
        final int pictures = (codecConfig || info.size == 0) ? 0 : 1;

        if (!pipeline.released) {
          packetCallback.onPacket(bytes, pictures, info.presentationTimeUs, eos, generation);
        }
        if (eos) {
          pipeline.eosLatch.countDown();
        }
      } finally {
        // Always release, even when the bytes were dropped.
        codec.releaseOutputBuffer(index, false);
      }
    }

    @Override
    public void onError(@NonNull MediaCodec codec, @NonNull MediaCodec.CodecException e) {
      // Unblock close() so it does not wait the full timeout on a dead encoder.
      pipeline.eosLatch.countDown();
    }

    @Override
    public void onOutputFormatChanged(@NonNull MediaCodec codec, @NonNull MediaFormat format) {
      // The caller owns the output format; nothing to do.
    }
  }

  private static String selectHardwareEncoder(String mimeType) {
    final String[] preferred;
    if (HEVC_MIME.equalsIgnoreCase(mimeType)) {
      preferred = new String[] {"c2.mtk.hevc.encoder", "OMX.MTK.VIDEO.ENCODER.HEVC"};
    } else if (AVC_MIME.equalsIgnoreCase(mimeType)) {
      preferred = new String[] {"c2.mtk.avc.encoder", "OMX.MTK.VIDEO.ENCODER.AVC"};
    } else {
      throw new IllegalArgumentException("Unsupported MIME type: " + mimeType);
    }

    final MediaCodecInfo[] infos = new MediaCodecList(MediaCodecList.ALL_CODECS).getCodecInfos();

    // 1. The device-preferred hardware encoder, by exact name.
    for (String name : preferred) {
      for (MediaCodecInfo info : infos) {
        if (info.isEncoder() && name.equals(info.getName()) && supportsType(info, mimeType)) {
          return name;
        }
      }
    }
    // 2. Any hardware encoder for this MIME.
    for (MediaCodecInfo info : infos) {
      if (info.isEncoder() && supportsType(info, mimeType) && isHardware(info)) {
        return info.getName();
      }
    }
    throw new IllegalStateException(
        "No hardware "
            + mimeType
            + " encoder available; refusing to fall back to a software encoder.");
  }

  private static boolean supportsType(MediaCodecInfo info, String mimeType) {
    for (String type : info.getSupportedTypes()) {
      if (type.equalsIgnoreCase(mimeType)) {
        return true;
      }
    }
    return false;
  }

  private static boolean isHardware(MediaCodecInfo info) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      return info.isHardwareAccelerated();
    }
    final String name = info.getName().toLowerCase(Locale.US);
    return !(name.startsWith("omx.google.") || name.startsWith("c2.android."));
  }
}
