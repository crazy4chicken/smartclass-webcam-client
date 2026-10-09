#ifndef ENCODED_STREAM_HANDLER_H_
#define ENCODED_STREAM_HANDLER_H_

#include <flutter_linux/flutter_linux.h>
#include <gst/gst.h>

#include <atomic>
#include <memory>
#include <string>
#include <vector>

// Which codec an encoded stream is asked to produce.
//
// Named for the wire, not for GStreamer: `start_recording.codec` is a closed
// seven-value vocabulary, and this device only implements the two that have an
// Annex B form. `mjpeg` needs no encoder at all — a JPEG already is one.
enum class EncodedCodec { kH264, kH265 };

// A second branch off the preview tee that produces *encoded* access units.
//
// Where RecordHandler writes a file, this hands compressed bytes to Dart. That
// is the whole point: the device cannot hold 1080p60 through `takePicture()`,
// because that is a full still capture plus a JPEG encode per frame. The
// frames have to be encoded where they are produced.
//
// Shape, mirroring RecordHandler so the fork stays recognisable:
//
//   tee → queue → valve → videoconvert → encoder → parse → capsfilter → appsink
//
// Three things this branch does that the recording branch does not:
//
// * **One buffer, one access unit.** The capsfilter pins
//   `stream-format=byte-stream,alignment=au`, so every appsink buffer is one
//   whole coded picture. Dart is told `pictures = 1` for each, and its
//   splitter cross-checks that against what it can actually cut — if the two
//   ever disagree, the packet is dropped rather than sent on.
// * **Parameter sets travel in band.** The server stores `recording.frame`
//   bodies verbatim with no container, so a consumer that tunes in mid-stream
//   has nothing to sync on but a key frame carrying VPS/SPS/PPS.
// * **No tail to flush, deliberately.** The branch is configured for
//   zero-latency, no-B-frame encoding, so the encoder holds nothing back and
//   closing the valve loses no frames. Stop additionally returns the branch to
//   NULL, so the next recording starts on a fresh encoder — which is what
//   guarantees its first unit is an IDR with its parameter sets attached.
//   (Add B-frames and both of those stop being true.)
class EncodedStreamHandler {
 public:
  EncodedStreamHandler();
  ~EncodedStreamHandler();

  // The GStreamer element factory that will encode [codec] on this machine,
  // or an empty string when this machine cannot encode it.
  //
  // Hardware first. A software encoder that can hold 1080p60 exists, but it
  // costs most of a core to do it while a preview pipeline runs alongside, so
  // a machine with a hardware path should be using it. Falling back to
  // software is not a failure either — what decides whether a rate is
  // announced is the measured throughput, not which element produced it, and
  // a machine with no encoder at all simply does not announce that codec.
  static std::string DetectEncoder(EncodedCodec codec);

  // The codecs this machine can encode, as wire names: "h264", "h265".
  //
  // Empty is a correct answer. The device always has `mjpeg` on top of
  // whatever comes back here, because `takePicture()` works everywhere.
  static std::vector<std::string> AvailableEncoders();

  // Reads a wire codec name. False for anything this branch cannot produce —
  // including `mjpeg`, which is a valid wire codec but has no encoder here
  // (a JPEG already is one) and is served by the still-picture path instead.
  static bool ParseCodec(const std::string& wire_name, EncodedCodec* out);

  // Attaches a branch for every codec this machine can encode.
  //
  // Built up front rather than on demand: adding elements to a PLAYING
  // pipeline is legal but the failure modes are ugly, and there are at most
  // two branches. Each sits behind a closed valve, which costs an encoder's
  // worth of memory and no CPU.
  //
  // |channel| and |camera_id| are what a unit is delivered on. The channel is
  // borrowed — it belongs to the plugin and outlives this handler.
  bool Setup(GstElement* pipeline, GstElement* tee, FlMethodChannel* channel,
             int camera_id, GError** error);

  // Opens the branch for [codec]. Returns false, with |error| set, when this
  // machine has no encoder for it — the caller acks `ok:false` rather than
  // recording something else and calling it success.
  bool Start(EncodedCodec codec, int fps, int bitrate, GError** error);

  // Closes the valve and parks the branch. Idempotent.
  void Stop();

  bool is_running() const { return running_branch_ != nullptr; }

  // Units the branch produced and did not deliver, because Dart had not
  // consumed the previous one. Diagnostic: a steadily climbing number here is
  // an encoder outrunning the link, and the fix is a lower declared rate, not
  // a bigger queue.
  int dropped_packets() const { return dropped_packets_.load(); }

 private:
  // One codec's worth of branch. Only built when an encoder for it exists.
  struct Branch {
    EncodedCodec codec = EncodedCodec::kH264;
    std::string encoder_name;
    bool built = false;
    GstElement* queue = nullptr;       // Owned by pipeline.
    GstElement* valve = nullptr;       // Owned by pipeline.
    GstElement* convert = nullptr;     // Owned by pipeline.
    GstElement* encoder = nullptr;     // Owned by pipeline.
    GstElement* parse = nullptr;       // Owned by pipeline.
    GstElement* capsfilter = nullptr;  // Owned by pipeline.
    GstElement* sink = nullptr;        // Owned by pipeline.
  };

  // Runs on a GStreamer streaming thread: copies the unit and hands it to the
  // main thread. Touches no Flutter state.
  static GstFlowReturn OnNewSample(GstAppSink* sink, gpointer user_data);

  bool BuildBranch(Branch* branch, const char* suffix, GError** error);
  Branch* BranchFor(EncodedCodec codec);
  void ConfigureEncoder(const Branch& branch, int fps, int bitrate);

  GstElement* pipeline_ = nullptr;      // Not owned.
  GstElement* tee_ = nullptr;           // Not owned.
  FlMethodChannel* channel_ = nullptr;  // Not owned; lives as long as the plugin.
  int camera_id_ = 0;

  // Reserved to two, and never grown after Setup, so `running_branch_` cannot
  // be invalidated by a reallocation.
  std::vector<Branch> branches_;
  Branch* running_branch_ = nullptr;

  // Units queued on the main loop but not yet delivered.
  //
  // A shared_ptr because the queued callbacks outlive nothing in particular:
  // they hold the counter themselves, so a callback that lands after this
  // handler is gone still decrements a live object. Same reasoning as
  // `Camera::image_stream_in_flight_`.
  std::shared_ptr<std::atomic<int>> in_flight_ =
      std::make_shared<std::atomic<int>>(0);

  std::atomic<int> dropped_packets_{0};
};

#endif  // ENCODED_STREAM_HANDLER_H_
