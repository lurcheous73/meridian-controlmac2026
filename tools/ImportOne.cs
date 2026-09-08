// Experimental, explicitly requested single-track FLAC import.
// Source audio is transferred unchanged. No existing media is overwritten.
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using Sooloos.Broker;
using Sooloos.Msg.Import;
using Sooloos.Msg.ImportDevice;
using Sooloos.Msg.AuxDevice;

internal static class ImportOne
{
    static string Tool(string name) {
        string root = Environment.GetEnvironmentVariable("CONTROLMAC_TOOL_DIR");
        if (!String.IsNullOrEmpty(root)) {
            string bundled = Path.Combine(root, name);
            if (File.Exists(bundled)) return bundled;
        }
        return name;
    }

    static Connection connection;
    static Sooid device;
    static Guid project;
    static string path, encoded, host;
    static byte[] originalHash;
    static FlacMetadata metadata;
    static double gain, peak;
    static int realStart, realEnd, noiseStart, noiseEnd;
    static readonly ManualResetEvent done = new ManualResetEvent(false);
    static int result = 1, connected, registered, copying, approved;
    static bool owned;
    static LightAlbumMetadata currentMetadata;
    static string[] covers;
    static bool unrelatedLookup;
    static int finalizing;

    static string Quote(string text) {
        if (text.IndexOfAny(new[] {'\r','\n','\0'}) >= 0) throw new ArgumentException("Unsupported control character in path.");
        return "\"" + text.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
    static Process Start(string executable, string arguments) {
        var p = new Process { StartInfo = new ProcessStartInfo(executable, arguments) {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true } };
        p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) Console.Error.WriteLine(e.Data); };
        p.Start(); p.BeginErrorReadLine(); return p;
    }
    static byte[] Hash(string filename) {
        using (var s = File.OpenRead(filename)) using (var sha = SHA256.Create()) return sha.ComputeHash(s);
    }
    static bool Equal(byte[] a, byte[] b) { return Convert.ToBase64String(a) == Convert.ToBase64String(b); }
    static void Analyze() {
        if (metadata.Channels != 2 || metadata.Bits != 24 || metadata.Rate != 44100)
            throw new NotSupportedException("This first importer supports stereo 24-bit/44.1 kHz FLAC only.");
        using (var p = Start(Tool("metaflac"), "--scan-replay-gain " + Quote(path))) {
            string output = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(); if (p.ExitCode != 0) throw new IOException("ReplayGain scan failed.");
            var parts = output.Split(new[] {' ','\t'}, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 4) throw new IOException("Invalid ReplayGain output.");
            gain = double.Parse(parts[parts.Length - 4], CultureInfo.InvariantCulture);
            peak = double.Parse(parts[parts.Length - 3], CultureInfo.InvariantCulture);
            if (double.IsNaN(gain) || double.IsInfinity(gain) || peak < 0 || peak > 1 || double.IsNaN(peak))
                throw new IOException("Invalid loudness values.");
        }
        // Decode and validate the complete source; locate digital silence and
        // a conservative -60 dBFS noise threshold. Never rewrite the audio.
        long frames = 0, first = -1, last = -1, firstNoise = -1, lastNoise = -1;
        using (var p = Start(Tool("flac"), "--decode --silent --stdout --force-raw-format --endian=little --sign=signed " + Quote(path))) {
            var stream = new BufferedStream(p.StandardOutput.BaseStream, 65536);
            byte[] frame = new byte[6];
            while (true) {
                int got = 0;
                while (got < 6) { int n = stream.Read(frame, got, 6 - got); if (n == 0) break; got += n; }
                if (got == 0) break;
                if (got != 6 || frames >= metadata.Samples) { p.Kill(); throw new InvalidDataException("PCM length mismatch."); }
                int amplitude = 0;
                for (int channel = 0; channel < 2; ++channel) {
                    int i = channel * 3;
                    int sample = frame[i] | (frame[i+1] << 8) | (frame[i+2] << 16);
                    if ((sample & 0x800000) != 0) sample |= unchecked((int)0xff000000);
                    amplitude = Math.Max(amplitude, Math.Abs(sample));
                }
                if (amplitude > 0) { if (first < 0) first = frames; last = frames; }
                if (amplitude > 8389) { if (firstNoise < 0) firstNoise = frames; lastNoise = frames; }
                ++frames;
            }
            p.WaitForExit();
            if (p.ExitCode != 0 || frames != metadata.Samples) throw new InvalidDataException("FLAC decoding/integrity check failed.");
        }
        realStart = (int)(Math.Max(0, first) * 1000 / metadata.Rate);
        realEnd = (int)((last < 0 ? frames : last + 1) * 1000 / metadata.Rate);
        noiseStart = firstNoise < 0 ? realStart : (int)(firstNoise * 1000 / metadata.Rate);
        noiseEnd = lastNoise < 0 ? realEnd : (int)((lastNoise + 1) * 1000 / metadata.Rate);
        if (!Equal(originalHash, Hash(path))) throw new IOException("Source changed during analysis.");
        Console.WriteLine("Validated FLAC; gain=" + gain + " dB; peak=" + peak + "; duration=" + metadata.Samples * 1000 / metadata.Rate + " ms");
    }
    static void Broadcast(IMessage message) {
        connection.Message.SendRequest(new AuxDeviceBroadcastRequest { DeviceId = device, Message = message });
    }
    static string[] UploadCover() {
        string cover = Path.Combine(Path.GetDirectoryName(path), "cover.jpg");
        if (!File.Exists(cover)) return new string[0];
        var bytes = File.ReadAllBytes(cover);
        if (bytes.Length > 16 * 1024 * 1024 || bytes.Length < 3 || bytes[0] != 255 || bytes[1] != 216)
            throw new InvalidDataException("Unsupported cover image.");
        var request = (HttpWebRequest)WebRequest.Create("http://" + host + "/upload/");
        request.Method = "POST"; request.ContentType = "application/octet-stream";
        request.ContentLength = bytes.Length; request.Proxy = null; request.AllowAutoRedirect = false; request.Timeout = 30000;
        using (var output = request.GetRequestStream()) output.Write(bytes, 0, bytes.Length);
        using (var response = request.GetResponse()) using (var input = new StreamReader(response.GetResponseStream())) {
            string value = input.ReadToEnd().Trim();
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Scheme != "http" || uri.Host != host)
                throw new InvalidDataException("Unexpected cover upload response.");
            Console.WriteLine("Cover uploaded.");
            return new[] { value };
        }
    }
    static void RejectExistingAlbum() {
        BrokerProbe.Initialize();
        var check = new Connection(host); var ready = new ManualResetEvent(false);
        check.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) { if (status.ToString() == "Connected") ready.Set(); };
        try {
            check.Connect();
            if (!ready.WaitOne(15000)) throw new IOException("Cannot check Core for an existing album.");
            var found = ImportVerification.Request(check, new Sooloos.Msg.Music.FastSearchRequest {
                Substring = metadata.Get("ALBUM"), MaxAlbumCount = 100, MaxTrackCount = 1
            }) as Sooloos.Msg.Music.FastSearchResponse;
            if (found == null) throw new IOException("Core album search failed.");
            if (found.Albums != null && found.Albums.Count != 0)
                throw new InvalidOperationException("An album matches this title. Import stopped to avoid duplicates.");
        } finally { check.Disconnect(); }
    }
    static void State(Sooid id, ImportMediaStatus status, bool duplicate) {
        Console.WriteLine("Album status: " + status + "; duplicate=" + duplicate);
        if (duplicate) { Console.Error.WriteLine("Existing album detected; stopping without overwrite."); done.Set(); return; }
        if (status == ImportMediaStatus.WaitingForApproval && Interlocked.Exchange(ref approved, 1) == 0)
            connection.Message.SendRequest(new MusicProjectReapplyUserMetadataRequest { ProjectId = project, AlbumId = id },
                delegate(IMessage response, bool final) {
                    if (!final) return;
                    if (!(response is Sooloos.Msg.Common.SuccessResponse)) { Console.Error.WriteLine("Could not restore file tags: " + response); done.Set(); return; }
                    if (covers.Length != 0)
                        connection.Message.SendRequest(new MusicProjectSetCoverUrlRequest { ProjectId = project, AlbumId = id, CoverUrl = covers[0] },
                            delegate(IMessage coverResponse, bool end) { if (end && coverResponse is Sooloos.Msg.Common.SuccessResponse) Approve(id); });
                    else Approve(id);
                });
        if (status == ImportMediaStatus.Complete && Interlocked.Exchange(ref finalizing, 1) == 0)
            ThreadPool.QueueUserWorkItem(delegate {
                try { ImportVerification.Verify(connection, id, path, unrelatedLookup); result = 0; }
                catch (Exception error) { Console.Error.WriteLine("Post-import verification failed: " + error.Message); }
                finally { done.Set(); }
            });
        if (status == ImportMediaStatus.Failed) done.Set();
    }
    static void Approve(Sooid id) {
        if (currentMetadata == null || currentMetadata.Name != metadata.Get("ALBUM") || currentMetadata.ArtistName != metadata.Get("ARTIST") ||
            currentMetadata.Tracks == null || currentMetadata.Tracks.Count != 1 || currentMetadata.Tracks[0].Name != metadata.Get("TITLE")) {
            Console.Error.WriteLine("Core metadata does not match source tags; refusing approval."); done.Set(); return;
        }
        Console.WriteLine("Core album, artist and track names match source tags.");
        connection.Message.SendRequest(new ImportProjectApproveRequest { ProjectId = project, MediaId = id, ClobberDuplicatesByName = false });
    }
    static void ProjectState(IMessage response, bool final) {
        var change = response as ImportProjectUpdatedResponse;
        if (change == null) { Console.WriteLine("Project: " + response.GetType().Name); return; }
        if (change.MediaUpdated != null) foreach (var m in change.MediaUpdated) {
            currentMetadata = m.LightMetadata as LightAlbumMetadata;
            if (currentMetadata != null && (currentMetadata.Name != metadata.Get("ALBUM") || currentMetadata.ArtistName != metadata.Get("ARTIST"))) unrelatedLookup = true;
        }
        if (change.MediaAdded != null) foreach (var m in change.MediaAdded) { currentMetadata = m.MetadataPackage.LightMetadata as LightAlbumMetadata; State(m.MetadataPackage.MediaId, m.Status, m.IsDuplicate); }
        if (change.MediaStatusUpdated != null) foreach (var m in change.MediaStatusUpdated) State(m.MediaId, m.Status, m.IsDuplicate);
    }
    static void Transfer(MediaCopyCommand copy) {
        try {
            if (copy.ProjectId != project || copy.Media == null || copy.Media.Count != 1 || copy.Media[0].MediaPath != encoded)
                throw new InvalidDataException("Unexpected transfer request; no files sent.");
            var extra = copy.ExtraInfo as AlbumCopyExtraInfo;
            if (extra == null || extra.Tracks.Count != 1 || extra.Tracks[0].MediaPath != encoded)
                throw new InvalidDataException("Unexpected track analysis request.");
            var target = new Uri(copy.Media[0].TargetUrl);
            if (target.Scheme != "http" || target.Host != host || target.UserInfo.Length != 0)
                throw new InvalidDataException("Core requested a different transfer host: " + target.Host);
            if (!Equal(originalHash, Hash(path))) throw new IOException("Source changed before transfer.");
            var upload = (HttpWebRequest)WebRequest.Create(target);
            upload.Method = "PUT"; upload.AllowAutoRedirect = false; upload.AllowWriteStreamBuffering = false;
            upload.ContentType = "application/octet-stream"; upload.ContentLength = new System.IO.FileInfo(path).Length;
            upload.Timeout = 120000; upload.ReadWriteTimeout = 120000; upload.Proxy = null;
            using (var input = File.OpenRead(path)) using (var output = upload.GetRequestStream()) input.CopyTo(output);
            using (var response = (HttpWebResponse)upload.GetResponse()) {
                if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300) throw new IOException("Audio upload rejected.");
            }
            Console.WriteLine("Audio PUT accepted by Core.");
            // Compare the stored bytes before declaring copy completion.
            var verify = (HttpWebRequest)WebRequest.Create(target);
            verify.AllowAutoRedirect = false; verify.Proxy = null; verify.Timeout = 120000;
            using (var response = verify.GetResponse()) using (var input = response.GetResponseStream()) using (var sha = SHA256.Create())
                if (!Equal(originalHash, sha.ComputeHash(input))) throw new IOException("Stored audio checksum mismatch.");
            Console.WriteLine("Stored audio SHA-256 matches original.");
            Broadcast(new ProjectExtraInfoBroadcast { ProjectId = project, ExtraInfo = new LooseFilesExtraInfo {
                Albums = new[] { new AlbumExtraInfo { AlbumId = extra.AlbumId, AlbumGain = gain, AlbumPeak = peak,
                    Tracks = new[] { new TrackExtraInfo { TrackNumber = extra.Tracks[0].TrackNumber,
                        TrackGain = gain, TrackPeak = peak, RealStartMs = realStart, RealEndMs = realEnd,
                        NoiseStartMs = noiseStart, NoiseEndMs = noiseEnd } } } }
            } });
            Broadcast(new MediaCopyStatusBroadcast { CopyId = copy.CopyId, CopyPercent = 100 });
        } catch (Exception error) {
            Console.Error.WriteLine("Transfer failed: " + error.Message);
            Broadcast(new MediaCopyStatusBroadcast { CopyId = copy.CopyId, CopyPercent = 0, FailureMessage = error.Message });
            done.Set();
        }
    }
    public static int Main(string[] args) {
        if (args.Length != 3 || args[0] != "--import") { Console.Error.WriteLine("Usage: ImportOne --import CORE_HOST TRACK.flac"); return 2; }
        try {
            host = args[1]; path = Path.GetFullPath(args[2]);
            metadata = FlacMetadata.Load(path);
            if (metadata.Get("ALBUM").Length == 0 || metadata.Get("ARTIST").Length == 0 || metadata.Get("TITLE").Length == 0)
                throw new InvalidDataException("Album, artist and title tags are required.");
            RejectExistingAlbum();
            originalHash = Hash(path); Analyze();
            encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(path));
            covers = UploadCover();
            BrokerProbe.Initialize(); connection = new Connection(host); device = new Sooid(24, Guid.NewGuid());
            connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
                if (status.ToString() != "Connected" || Interlocked.Exchange(ref connected, 1) != 0) return;
                connection.Message.SendRequest(new AuxDeviceConnectRequest { Info = new AuxDeviceInfo {
                    DeviceId = device, Description = "ControlMac2026 FLAC import", Capabilities = new[] { Capabilities.Import },
                    ConfigurationType = ConfigurationType.Static }, PingSeconds = 20
                }, delegate(IMessage response, bool final) {
                    var incoming = response as AuxDeviceMessageResponse;
                    if (incoming != null) {
                        var copy = incoming.Message as MediaCopyCommand;
                        if (copy != null && Interlocked.Exchange(ref copying, 1) == 0) ThreadPool.QueueUserWorkItem(delegate { Transfer(copy); });
                        else Console.WriteLine("Device message: " + incoming.Message);
                    }
                    if (!(response is AuxDeviceConnectResponse) || Interlocked.Exchange(ref registered, 1) != 0) return;
                    connection.Message.SendRequest(new CreateLooseFilesMusicProjectRequest {
                        ImportDeviceId = device, CreateOptions = new[] { CreateOption.AutoSkipDuplicates, CreateOption.PreferUserMetadata, CreateOption.Private },
                        MusicFiles = new[] { new MusicFileInfo { FileInfo = new Sooloos.Msg.Import.FileInfo {
                            MediaPath = encoded, OriginalPath = path, FileSize = new System.IO.FileInfo(path).Length, IsDirectory = false },
                            ExtractedTags = metadata.Tags, CoverUrls = covers } }
                    }, delegate(IMessage message, bool last) {
                        var created = message as ProjectCreatedResponse;
                        if (created != null) {
                            project = created.ProjectId; owned = !created.ProjectAlreadyExists;
                            Console.WriteLine("Import project: " + project);
                            if (!owned) { done.Set(); return; }
                            connection.Message.SendRequest(new ImportProjectSubscribeRequest { ProjectId = project }, ProjectState);
                        }
                        if (message is ProjectCreationCompletedResponse && owned)
                            connection.Message.SendRequest(new LooseMusicFilesMakeAlbumRequest { ProjectId = project, MediaPaths = new[] { encoded },
                                CreateOptions = new[] { CreateOption.AutoSkipDuplicates, CreateOption.PreferUserMetadata, CreateOption.Private }
                            }, delegate(IMessage grouping, bool end) { Console.WriteLine("Grouping: " + grouping); });
                    });
                });
            };
            connection.Connect();
            using (var ping = new Timer(delegate(object state) {
                if (registered != 0) connection.Message.SendRequest(new AuxDevicePingRequest { DeviceId = device });
            }, null, 5000, 5000)) {
                if (!done.WaitOne(180000)) Console.Error.WriteLine("Timed out; inspect project " + project + " before retrying.");
            }
            Console.WriteLine(result == 0 ? "CORE CONFIRMED IMPORT COMPLETE" : "IMPORT NOT CONFIRMED COMPLETE; project=" + project);
            return result;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { if (connection != null) connection.Disconnect(); }
    }
}
