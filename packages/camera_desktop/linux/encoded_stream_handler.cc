#include "encoded_stream_handler.h"

#include <cstddef>
#include <cstdint>

namespace {

// Units allowed to be queued on the main loop at once.
//
// The link to Dart is a method channel, which is not a frame pipeline: if Dart
// has not consumed the previous unit, queueing more only converts a dropped
// frame into latency, and latency on a live camera reads as a broken one. Four
// is enough to absorb a main-loop hiccup without becoming a buffer.
const int kMaxInFlight = 4;

// Encoder candidates per codec, best first.
//
// Same shape as RecordHandler's list, extended: hardware first, because the
// device has to hold a high rate while a preview pipeline runs at the same
// time, and the software path costs most of a core to do it.
//
// The two VAAPI spellings both appear because they are different plugins —
// `vah264enc` is gst-plugins-bad's `va` element, `vaapih264enc` is
// gstreamer-vaapi's — and which one a distribution ships varies. Asking the
// factory is the only way to tell; there is no capability query to make.
const char* const kH264Candidates[] = {
    "vah264enc",
    "vaapih264enc",
    "nvv4l2h264enc",
    "x264enc",
    "openh264enc",
    "avenc_h264",
};

const char* const kH265Candidates[] = {
    "vah265enc",
    "vaapih265enc",
    "nvv4l2h265enc",
    "x265enc",
    "avenc_hevc",
};

template <std::size_t N>
std::string FirstPresent(const char* const (&candidates)[N]) {
  for (std::size_t i = 0; i < N; i++) {
    GstElementFactory* factory = gst_element_factory_find(candidates[i]);
    if (factory) {
      gst_object_unref(factory);
      return candidates[i];
    }
  }
  return "";
}

const char* SuffixFor(EncodedCodec codec) {
  return codec == EncodedCodec::kH265 ? "h265" : "h264";
}

// The parse element and the caps that pin one access unit per buffer.
//
// `alignment=au` is what lets the Dart side be told `pictures = 1` for every
// buffer instead of guessing. Without it a buffer can end mid-picture and the
// bytes are then only recoverable by a splitter that has to assume things.
const char* ParseElementFor(EncodedCodec codec) {
  return codec == EncodedCodec::kH265 ? "h265parse" : "h264parse";
}

std::string CapsedFor(EncodedCodec codec) {
  return codec == EncodedCodec::kH265
             ? "video/x-h265,stream-format=byte-stream,alignment=au"
             : "video/x-h264,stream-format=byte-stream,alignment=au";
}

// One unit on its way to the main thread.
struct PendingUnit {
  FlMethodChannel* channel;  // Borrowed; owned by the plugin.
  int camera_id;
  GBytes* bytes;  // Owned.
  // Kept alive by the callback itself, so a delivery that lands after the
  // handler is gone still decrements a live counter.
  std::shared_ptr<std::atomic<int>> in_flight;
};

// Delivers one unit to Dart on the main thread.
//
// `pictures` is 1 because the branch's capsfilter pins `alignment=au`: one
// buffer is one coded picture. That is an assumption about GStreamer rather
// than a fact about the bytes, which is exactly what the field is for — Dart
// cross-checks it against what it can cut, and drops the packet if the two
// disagree.
gboolean DeliverUnit(gpointer user_data) {
  PendingUnit* unit = static_cast<PendingUnit*>(user_data);

  gsize size = 0;
  const guchar* data =
      static_cast<const guchar*>(g_bytes_get_data(unit->bytes, &size));

  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "cameraId", fl_value_new_int(unit->camera_id));
  fl_value_set_string_take(args, "pictures", fl_value_new_int(1));
  fl_value_set_string_take(args, "bytes",
                           fl_value_new_uint8_list(
                               static_cast<const uint8_t*>(data), size));

  fl_method_channel_invoke_method(unit->channel, "encodedStreamPacket", args,
                                  nullptr, nullptr, nullptr);

  unit->in_flight->fetch_sub(1);
  g_bytes_unref(unit->bytes);
  delete unit;
  return G_SOURCE_REMOVE;
}

}  // namespace

EncodedStreamHandler::EncodedStreamHandler() {
  branches_.reserve(2);
}

EncodedStreamHandler::~EncodedStreamHandler() {
  // Nothing to free: every element belongs to the pipeline, and the queued
  // deliveries own their own bytes and counter.
}

std::string EncodedStreamHandler::DetectEncoder(EncodedCodec codec) {
  switch (codec) {
    case EncodedCodec::kH264:
      return FirstPresent(kH264Candidates);
    case EncodedCodec::kH265:
      return FirstPresent(kH265Candidates);
  }
  return "";
}

std::vector<std::string> EncodedStreamHandler::AvailableEncoders() {
  std::vector<std::string> codecs;
  if (!DetectEncoder(EncodedCodec::kH264).empty()) {
    codecs.push_back("h264");
  }
  if (!DetectEncoder(EncodedCodec::kH265).empty()) {
    codecs.push_back("h265");
  }
  return codecs;
}

bool EncodedStreamHandler::ParseCodec(const std::string& wire_name,
                                      EncodedCodec* out) {
  if (wire_name == "h264") {
    *out = EncodedCodec::kH264;
    return true;
  }
  if (wire_name == "h265") {
    *out = EncodedCodec::kH265;
    return true;
  }
  return false;
}

bool EncodedStreamHandler::Setup(GstElement* pipeline, GstElement* tee,
                                 FlMethodChannel* channel, int camera_id,
                                 GError** error) {
  pipeline_ = pipeline;
  tee_ = tee;
  channel_ = channel;
  camera_id_ = camera_id;

  for (const EncodedCodec codec : {EncodedCodec::kH264, EncodedCodec::kH265}) {
    Branch branch;
    branch.codec = codec;
    branch.encoder_name = DetectEncoder(codec);
    if (branch.encoder_name.empty()) {
      // No encoder is a correct answer, not a failure: the codec is simply
      // never announced, so nothing can ask for it. Logged because "why is
      // HEVC missing on this box" is otherwise unanswerable from the device.
      g_info("[camera_desktop] No %s encoder on this machine; the codec will "
             "not be announced", SuffixFor(codec));
      continue;
    }
    if (!BuildBranch(&branch, SuffixFor(codec), error)) {
      return false;
    }
    branch.built = true;
    branches_.push_back(branch);
  }

  if (branches_.empty()) {
    g_info("[camera_desktop] No H.264 or H.265 encoder available; recordings "
           "will be mjpeg only");
  }
  return true;
}

bool EncodedStreamHandler::BuildBranch(Branch* branch, const char* suffix,
                                       GError** error) {
  g_autofree gchar* queue_name = g_strdup_printf("enc_%s_queue", suffix);
  g_autofree gchar* valve_name = g_strdup_printf("enc_%s_valve", suffix);
  g_autofree gchar* convert_name = g_strdup_printf("enc_%s_convert", suffix);
  g_autofree gchar* encoder_name = g_strdup_printf("enc_%s_encoder", suffix);
  g_autofree gchar* parse_name = g_strdup_printf("enc_%s_parse", suffix);
  g_autofree gchar* caps_name = g_strdup_printf("enc_%s_caps", suffix);
  g_autofree gchar* sink_name = g_strdup_printf("enc_%s_sink", suffix);

  branch->queue = gst_element_factory_make("queue", queue_name);
  branch->valve = gst_element_factory_make("valve", valve_name);
  branch->convert = gst_element_factory_make("videoconvert", convert_name);
  branch->encoder =
      gst_element_factory_make(branch->encoder_name.c_str(), encoder_name);
  branch->parse = gst_element_factory_make(ParseElementFor(branch->codec),
                                           parse_name);
  branch->capsfilter = gst_element_factory_make("capsfilter", caps_name);
  branch->sink = gst_element_factory_make("appsink", sink_name);

  if (!branch->queue || !branch->valve || !branch->convert ||
      !branch->encoder || !branch->parse || !branch->capsfilter ||
      !branch->sink) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to create encoded stream elements for %s", suffix);
    return false;
  }

  // Closed until a recording asks for it, exactly like the recording branch.
  g_object_set(branch->valve, "drop", TRUE, nullptr);

  // Bounded, and leaking rather than growing: a branch that cannot keep up
  // must shed frames, because the alternative is a queue that turns into
  // latency. `2` is GST_QUEUE_LEAK_DOWNSTREAM — drop the oldest buffer to make
  // room for the newest, which is what a live camera wants. (Confirm the
  // direction by measurement on the target box: if it is backwards the
  // symptom is latency creeping up rather than anything louder.)
  g_object_set(branch->queue,
               "max-size-buffers", (guint)2,
               "max-size-time",    (guint64)0,
               "max-size-bytes",   (guint)0,
               "leaky",            (gint)2,
               nullptr);

  // Parameter sets before every key frame, so a consumer that tunes in
  // mid-stream can start decoding without out-of-band configuration. The
  // server stores bare frames with no container, so there is nowhere else for
  // them to come from.
  g_object_set(branch->parse, "config-interval", -1, nullptr);

  g_autoptr(GstCaps) caps = gst_caps_from_string(CapsedFor(branch->codec).c_str());
  g_object_set(branch->capsfilter, "caps", caps, nullptr);

  // Never drop silently at the sink, and never block the pipeline: one buffer
  // deep, and the queue above is what bounds the rest.
  g_object_set(branch->sink,
               "emit-signals", TRUE,
               "sync", FALSE,
               "max-buffers", (guint)1,
               "drop", FALSE,
               nullptr);

  GstAppSinkCallbacks callbacks = {};
  callbacks.new_sample = &EncodedStreamHandler::OnNewSample;
  gst_app_sink_set_callbacks(GST_APP_SINK(branch->sink), &callbacks, this,
                             nullptr);

  gst_bin_add_many(GST_BIN(pipeline_), branch->queue, branch->valve,
                   branch->convert, branch->encoder, branch->parse,
                   branch->capsfilter, branch->sink, nullptr);

  if (!gst_element_link_many(branch->queue, branch->valve, branch->convert,
                             branch->encoder, branch->parse, branch->capsfilter,
                             branch->sink, nullptr)) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to link encoded stream branch for %s", suffix);
    return false;
  }

  // Same request-pad dance the recording branch does: `src_%u` is a request
  // pad on a tee, and the spelling of the API changed in 1.20.
#if GST_CHECK_VERSION(1, 20, 0)
  GstPad* tee_pad = gst_element_request_pad_simple(tee_, "src_%u");
#else
  GstPad* tee_pad = gst_element_get_request_pad(tee_, "src_%u");
#endif
  GstPad* queue_pad = gst_element_get_static_pad(branch->queue, "sink");
  const GstPadLinkReturn link_ret = gst_pad_link(tee_pad, queue_pad);
  gst_object_unref(queue_pad);
  gst_object_unref(tee_pad);

  if (link_ret != GST_PAD_LINK_OK) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "Failed to link tee to the encoded stream branch for %s",
                suffix);
    return false;
  }

  // Deliberately *not* synced with the pipeline here. A bin pushes its state
  // to its children when the pipeline changes, so the branch will follow the
  // pipeline to PLAYING on its own — and that is fine: the valve is shut, so
  // the encoder idles. `Start` is what brings the branch back from NULL after
  // a previous recording parked it.
  return true;
}

EncodedStreamHandler::Branch* EncodedStreamHandler::BranchFor(
    EncodedCodec codec) {
  for (Branch& branch : branches_) {
    if (branch.codec == codec) {
      return &branch;
    }
  }
  return nullptr;
}

void EncodedStreamHandler::ConfigureEncoder(const Branch& branch, int fps,
                                            int bitrate) {
  const std::string& name = branch.encoder_name;
  const int kbps = bitrate > 0 ? (bitrate / 1000) : 0;

  // Only properties that RecordHandler already sets, on the same elements.
  // A property an element does not have is not a warning you can shrug off —
  // `g_object_set` raises a GLib critical and carries on, which is the worst
  // of both worlds — so anything not already proven here is left at its
  // default rather than guessed at.
  if (name == "x264enc") {
    g_object_set(branch.encoder,
                 "tune", 4,          // zerolatency
                 "speed-preset", 1,  // ultrafast
                 "bitrate", kbps > 0 ? kbps : 4000,
                 nullptr);
  } else if (name == "openh264enc") {
    g_object_set(branch.encoder, "bitrate",
                 bitrate > 0 ? bitrate : 4000000, nullptr);
  } else if (name == "vah264enc" || name == "vaapih264enc") {
    if (kbps > 0) {
      g_object_set(branch.encoder, "bitrate", kbps, nullptr);
    }
  }

  // A key frame at least every two seconds, so a consumer that joins late
  // never waits long. Only set where the element is known to have it.
  if (name == "x264enc" || name == "x265enc") {
    const int key_int_max = fps > 0 ? fps * 2 : 60;
    g_object_set(branch.encoder, "key-int-max", key_int_max, nullptr);
  }
}

bool EncodedStreamHandler::Start(EncodedCodec codec, int fps, int bitrate,
                                 GError** error) {
  Stop();

  Branch* branch = BranchFor(codec);
  if (branch == nullptr) {
    g_set_error(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                "No %s encoder available on this machine",
                SuffixFor(codec));
    return false;
  }

  ConfigureEncoder(*branch, fps, bitrate);

  // Back to the pipeline's state first, then open the valve. The other order
  // would let buffers into an element that is not running.
  gst_element_sync_state_with_parent(branch->queue);
  gst_element_sync_state_with_parent(branch->valve);
  gst_element_sync_state_with_parent(branch->convert);
  gst_element_sync_state_with_parent(branch->encoder);
  gst_element_sync_state_with_parent(branch->parse);
  gst_element_sync_state_with_parent(branch->capsfilter);
  gst_element_sync_state_with_parent(branch->sink);

  g_object_set(branch->valve, "drop", FALSE, nullptr);

  running_branch_ = branch;
  return true;
}

void EncodedStreamHandler::Stop() {
  if (running_branch_ == nullptr) {
    return;
  }

  // Close the valve first: from here nothing new reaches the encoder, and the
  // branch is parked before anything is torn down.
  g_object_set(running_branch_->valve, "drop", TRUE, nullptr);

  // Then park the branch in NULL. This is what makes the *next* recording
  // start correctly: a fresh encoder always opens with an IDR carrying its
  // parameter sets, so the first unit of every recording is decodable on its
  // own. An encoder left running would continue with a P-frame, and a
  // recording that begins with an undecodable unit is a recording whose first
  // seconds are lost — invisibly, because the server stores bytes verbatim.
  gst_element_set_state(running_branch_->sink, GST_STATE_NULL);
  gst_element_set_state(running_branch_->capsfilter, GST_STATE_NULL);
  gst_element_set_state(running_branch_->parse, GST_STATE_NULL);
  gst_element_set_state(running_branch_->encoder, GST_STATE_NULL);
  gst_element_set_state(running_branch_->convert, GST_STATE_NULL);
  gst_element_set_state(running_branch_->valve, GST_STATE_NULL);
  gst_element_set_state(running_branch_->queue, GST_STATE_NULL);

  running_branch_ = nullptr;
}

GstFlowReturn EncodedStreamHandler::OnNewSample(GstAppSink* sink,
                                                gpointer user_data) {
  EncodedStreamHandler* self = static_cast<EncodedStreamHandler*>(user_data);

  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_ERROR;
  }

  GstBuffer* buffer = gst_sample_get_buffer(sample);
  if (buffer == nullptr) {
    gst_sample_unref(sample);
    return GST_FLOW_ERROR;
  }

  // Copy, then hand the copy to the main thread. Nothing Flutter-shaped is
  // touched from here: this is a GStreamer streaming thread, and the channel
  // belongs to the main thread.
  GstMapInfo map;
  if (!gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    gst_sample_unref(sample);
    return GST_FLOW_ERROR;
  }

  if (map.size > 0) {
    if (self->in_flight_->load() >= kMaxInFlight) {
      self->dropped_packets_.fetch_add(1);
    } else {
      self->in_flight_->fetch_add(1);
      PendingUnit* unit = new PendingUnit();
      unit->channel = self->channel_;
      unit->camera_id = self->camera_id_;
      unit->bytes = g_bytes_new(map.data, map.size);
      unit->in_flight = self->in_flight_;
      g_idle_add(DeliverUnit, unit);
    }
  }

  gst_buffer_unmap(buffer, &map);
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}
