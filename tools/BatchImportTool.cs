using System;
using System.IO;
using System.Net;
using System.Text;
using System.Linq;
using System.Threading;
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Collections.Generic;
using Sooloos.Broker;
using Sooloos.Msg.Import;
using Sooloos.Msg.ImportDevice;
using Sooloos.Msg.AuxDevice;
using Sooloos.Msg.Music;

internal static class BatchImportTool {
    static string Tool(string name) {
        string root = Environment.GetEnvironmentVariable("CONTROLMAC_TOOL_DIR");
        if (!String.IsNullOrEmpty(root)) {
            string bundled = Path.Combine(root, name);
            if (File.Exists(bundled)) return bundled;
        }
        return name;
    }

    sealed class TrackSource {
        public string Path, Encoded, Artist, Album, Title;
        public int Disc, Track, DurationMs, Rate, Bits, Channels;
        public long Size;
        public double Gain, Peak;
        public byte[] Hash;
    }
    static Connection connection;
    static Sooid device;
    static Guid project;
    static string host;
    static List<TrackSource> tracks;
    static readonly ManualResetEvent done = new ManualResetEvent(false);
    static int result = 1, connected, registered, copying, approved, finalizing;
    static Sooid importedAlbumId;
    static LightAlbumMetadata currentMetadata;
    static double albumGain, albumPeak;
    static bool editionMode;
    static bool duplicateSemanticsTest;
    static int earlyReapplySent;
    static string cancelPath;
    static bool ownedProject;

    static bool CancelRequested() { return !String.IsNullOrEmpty(cancelPath) && File.Exists(cancelPath); }
    static void CheckCancel() {
        if (!CancelRequested()) return;
        Console.WriteLine("IMPORT_CANCELLED"); Console.Out.Flush();
        throw new OperationCanceledException("Import cancelled.");
    }

    static string Decode(string value) {
        return Encoding.UTF8.GetString(Convert.FromBase64String(value));
    }
    static string Quote(string text) {
        if (text.IndexOfAny(new[] {'\r','\n','\0'}) >= 0) throw new ArgumentException("Unsupported control character in path.");
        return "\"" + text.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
    static Process Start(string executable, string arguments) {
        var p = new Process { StartInfo = new ProcessStartInfo(executable, arguments) {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true } };
        p.Start(); return p;
    }
    static byte[] Hash(string filename) {
        using (var s = File.OpenRead(filename)) using (var sha = SHA256.Create()) return sha.ComputeHash(s);
    }
    static bool Equal(byte[] a, byte[] b) { return a.SequenceEqual(b); }
    static string ProgressText(string value) {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(value ?? ""));
    }
    static void Progress(string phase, TrackSource t, long current, long total) {
        Console.WriteLine("CMPROGRESS\t" + phase + "\t" + t.Track + "\t" + tracks.Count + "\t" + current + "\t" + total + "\t" + ProgressText(t.Title));
        Console.Out.Flush();
    }
    static List<TrackSource> LoadManifest(string path) {
        var list = new List<TrackSource>();
        foreach (var line in File.ReadAllLines(path)) {
            if (String.IsNullOrWhiteSpace(line)) continue;
            var f = line.Split('\t');
            if (f.Length < 10 || f[0] != "CMIMPORT") throw new InvalidDataException("Invalid import manifest.");
            var t = new TrackSource {
                Path = Path.GetFullPath(Decode(f[1])), Artist = Decode(f[2]), Album = Decode(f[3]), Title = Decode(f[4]),
                Disc = Int32.Parse(f[5], CultureInfo.InvariantCulture), Track = Int32.Parse(f[6], CultureInfo.InvariantCulture),
                Rate = Int32.Parse(f[7], CultureInfo.InvariantCulture), Bits = Int32.Parse(f[8], CultureInfo.InvariantCulture), Channels = Int32.Parse(f[9], CultureInfo.InvariantCulture)
            };
            if (!File.Exists(t.Path) || String.IsNullOrWhiteSpace(t.Artist) || String.IsNullOrWhiteSpace(t.Album) || String.IsNullOrWhiteSpace(t.Title))
                throw new InvalidDataException("Manifest contains a missing file or blank metadata.");
            t.Size = new System.IO.FileInfo(t.Path).Length;
            t.Encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(t.Path));
            t.Hash = Hash(t.Path);
            list.Add(t);
        }
        if (list.Count == 0) throw new InvalidDataException("Nothing to import.");
        string artist = list[0].Artist, album = list[0].Album;
        int disc = list[0].Disc;
        if (list.Any(t => t.Artist != artist || t.Album != album || t.Disc != disc))
            throw new InvalidDataException("One batch must contain one artist/album/disc.");
        if (list.Select(t => t.Track).Distinct().Count() != list.Count || list.Any(t => t.Track <= 0))
            throw new InvalidDataException("Track numbers must be unique and positive.");
        return list.OrderBy(t => t.Track).ToList();
    }
    static double ParseMetric(string text, string key) {
        foreach (var line in text.Split('\n')) {
            int at = line.IndexOf(key, StringComparison.OrdinalIgnoreCase);
            if (at < 0) continue;
            string value = line.Substring(at + key.Length).Trim().TrimStart('=').Trim();
            var token = value.Split(new[] {' ', '\r', '\t'}, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            double n;
            if (token != null && Double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out n)) return n;
        }
        throw new InvalidDataException("Could not read " + key + " from FFmpeg analysis.");
    }
    static void AnalyzeTrack(TrackSource t) {
        CheckCancel();
        Progress("ANALYZE", t, 0, 1);
        using (var probe = Start(Tool("ffprobe"), "-v error -select_streams a:0 -show_entries format=duration -of default=nw=1:nk=1 " + Quote(t.Path))) {
            string value = probe.StandardOutput.ReadToEnd().Trim(); probe.WaitForExit();
            double seconds;
            if (probe.ExitCode != 0 || !Double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out seconds) || seconds <= 0)
                throw new InvalidDataException("Could not read duration: " + Path.GetFileName(t.Path));
            t.DurationMs = (int)Math.Round(seconds * 1000.0);
        }
        using (var p = Start(Tool("ffmpeg"), "-hide_banner -nostats -i " + Quote(t.Path) + " -map 0:a:0 -af replaygain -f null -")) {
            string stdout = p.StandardOutput.ReadToEnd(); string stderr = p.StandardError.ReadToEnd(); p.WaitForExit();
            if (p.ExitCode != 0) throw new InvalidDataException("Audio decode failed: " + Path.GetFileName(t.Path));
            t.Gain = ParseMetric(stderr, "track_gain"); t.Peak = ParseMetric(stderr, "track_peak");
        }
        CheckCancel();
        if (!Equal(t.Hash, Hash(t.Path))) throw new IOException("Source changed during analysis: " + t.Path);
        Console.WriteLine("ANALYZED\t" + t.Track + "\t" + t.DurationMs + "\t" + t.Gain.ToString("0.00", CultureInfo.InvariantCulture) + "\t" + t.Peak.ToString("0.000000", CultureInfo.InvariantCulture));
        Progress("ANALYZE", t, 1, 1);
    }
    static string ConcatQuote(string path) {
        return "'" + path.Replace("'", "'\\''") + "'";
    }
    static void AnalyzeAlbum() {
        foreach (var t in tracks) { CheckCancel(); AnalyzeTrack(t); }
        string list = Path.Combine(Path.GetTempPath(), "controlmac-" + Guid.NewGuid().ToString("N") + ".ffconcat");
        try {
            using (var w = new StreamWriter(list, false, new UTF8Encoding(false))) {
                w.WriteLine("ffconcat version 1.0");
                foreach (var t in tracks) w.WriteLine("file " + ConcatQuote(t.Path));
            }
            using (var p = Start(Tool("ffmpeg"), "-hide_banner -nostats -f concat -safe 0 -i " + Quote(list) + " -map 0:a:0 -af replaygain -f null -")) {
                string stdout = p.StandardOutput.ReadToEnd(); string stderr = p.StandardError.ReadToEnd(); p.WaitForExit();
                if (p.ExitCode != 0) throw new InvalidDataException("Album ReplayGain analysis failed.");
                albumGain = ParseMetric(stderr, "track_gain"); albumPeak = ParseMetric(stderr, "track_peak");
            }
        } finally { try { File.Delete(list); } catch { } }
        Console.WriteLine("ALBUMGAIN\t" + albumGain.ToString("0.00", CultureInfo.InvariantCulture) + "\t" + albumPeak.ToString("0.000000", CultureInfo.InvariantCulture));
    }

    static List<MusicFileTag> Tags(TrackSource t) {
        var tags = new List<MusicFileTag>();
        tags.Add(new MusicFileTag { Name = "ARTIST", Value = t.Artist });
        tags.Add(new MusicFileTag { Name = "ALBUMARTIST", Value = t.Artist });
        tags.Add(new MusicFileTag { Name = "ALBUM", Value = t.Album });
        tags.Add(new MusicFileTag { Name = "TITLE", Value = t.Title });
        tags.Add(new MusicFileTag { Name = "TRACKNUMBER", Value = t.Track.ToString(CultureInfo.InvariantCulture) });
        tags.Add(new MusicFileTag { Name = "DISCNUMBER", Value = Math.Max(1, t.Disc).ToString(CultureInfo.InvariantCulture) });
        tags.Add(new MusicFileTag { Name = "length", Value = (t.DurationMs / 1000.0).ToString("0.###", CultureInfo.InvariantCulture) });
        tags.Add(new MusicFileTag { Name = "lengthms", Value = t.DurationMs.ToString(CultureInfo.InvariantCulture) });
        return tags;
    }
    static IMessage Request(Connection c, IMessage request) {
        IMessage response = null; var wait = new ManualResetEvent(false);
        c.Message.SendRequest(request, delegate(IMessage m, bool final) { response = m; if (final) wait.Set(); });
        if (!wait.WaitOne(20000)) throw new TimeoutException("Core request timed out.");
        return response;
    }
    static bool SameText(string a, string b) {
        return String.Equals((a ?? "").Trim(), (b ?? "").Trim(), StringComparison.OrdinalIgnoreCase);
    }
    static bool ExistingExactDuplicate() {
        var found = Request(connection, new FastSearchRequest { Substring = tracks[0].Album, MaxAlbumCount = 100, MaxTrackCount = 0 }) as FastSearchResponse;
        if (found == null || found.Albums == null) return false;
        foreach (var hit in found.Albums) {
            if (!SameText(hit.ArtistName, tracks[0].Artist) || !SameText(hit.AlbumName, tracks[0].Album)) continue;
            var album = Request(connection, new GetAlbumRequest { AlbumId = hit.AlbumId }) as Album;
            if (album == null || album.Tracks == null || album.Tracks.Count != tracks.Count) continue;
            bool match = true;
            foreach (var local in tracks) {
                var core = album.Tracks.FirstOrDefault(t => t.TrackNumber == local.Track);
                if (core == null || !SameText(core.TrackName, local.Title) || core.FileInfo == null || core.FileInfo.FileSize != local.Size) {
                    match = false; break;
                }
            }
            if (match) {
                Console.WriteLine("CMDUPLICATE\t" + album.AlbumId + "\t" + album.ArtistName + "\t" + album.AlbumName);
                return true;
            }
        }
        return false;
    }
    static readonly object copyLock = new object();
    static readonly HashSet<Guid> seenCopies = new HashSet<Guid>();
    static int extraInfoSent;

    static void Broadcast(IMessage message) {
        connection.Message.SendRequest(new AuxDeviceBroadcastRequest { DeviceId = device, Message = message });
    }
    static TrackSource FindTrack(string encoded) {
        var t = tracks.FirstOrDefault(x => x.Encoded == encoded);
        if (t == null) throw new InvalidDataException("Core requested an unknown media path.");
        return t;
    }
    static void Upload(TrackSource source, string targetValue) {
        CheckCancel();
        var target = new Uri(targetValue);
        if (target.Scheme != "http" || target.Host != host || target.UserInfo.Length != 0)
            throw new InvalidDataException("Core requested an unexpected upload target.");
        if (!Equal(source.Hash, Hash(source.Path))) throw new IOException("Source changed before transfer: " + source.Path);
        var upload = (HttpWebRequest)WebRequest.Create(target);
        upload.Method = "PUT"; upload.AllowAutoRedirect = false; upload.AllowWriteStreamBuffering = false;
        upload.ContentType = "application/octet-stream"; upload.ContentLength = source.Size;
        upload.Timeout = 180000; upload.ReadWriteTimeout = 180000; upload.Proxy = null;
        Progress("COPY", source, 0, source.Size);
        using (var input = File.OpenRead(source.Path)) using (var output = upload.GetRequestStream()) {
            byte[] buffer = new byte[1024 * 1024];
            long copied = 0, nextReport = 0;
            int count;
            while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                CheckCancel();
                output.Write(buffer, 0, count); copied += count;
                if (copied >= nextReport || copied == source.Size) {
                    Progress("COPY", source, copied, source.Size);
                    nextReport = copied + 1024 * 1024;
                }
            }
        }
        using (var response = (HttpWebResponse)upload.GetResponse()) {
            if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300) throw new IOException("Audio upload rejected.");
        }
        var verify = (HttpWebRequest)WebRequest.Create(target);
        verify.AllowAutoRedirect = false; verify.Proxy = null; verify.Timeout = 180000;
        using (var response = verify.GetResponse()) using (var input = response.GetResponseStream()) using (var sha = SHA256.Create())
            if (!Equal(source.Hash, sha.ComputeHash(input))) throw new IOException("Stored audio checksum mismatch.");
        Console.WriteLine("COPIED\t" + source.Track + "\t" + source.Size);
    }
    static void SendExtraInfo(Sooid albumId) {
        if (Interlocked.Exchange(ref extraInfoSent, 1) != 0) return;
        var extras = tracks.Select(t => new TrackExtraInfo {
            TrackNumber = t.Track, TrackGain = t.Gain, TrackPeak = t.Peak,
            RealStartMs = 0, RealEndMs = t.DurationMs, NoiseStartMs = 0, NoiseEndMs = t.DurationMs
        }).ToArray();
        Broadcast(new ProjectExtraInfoBroadcast { ProjectId = project, ExtraInfo = new LooseFilesExtraInfo {
            Albums = new[] { new AlbumExtraInfo { AlbumId = albumId, AlbumGain = albumGain, AlbumPeak = albumPeak, Tracks = extras } }
        } });
        Console.WriteLine("EXTRAINFO\t" + tracks.Count);
    }
    static void Transfer(MediaCopyCommand copy) {
        lock (copyLock) { if (!seenCopies.Add(copy.CopyId)) return; }
        try {
            if (copy.ProjectId != project || copy.Media == null || copy.Media.Count == 0)
                throw new InvalidDataException("Unexpected transfer request.");
            var extra = copy.ExtraInfo as AlbumCopyExtraInfo;
            if (extra == null || extra.Tracks == null || extra.Tracks.Count == 0)
                throw new InvalidDataException("Missing album transfer metadata.");
            importedAlbumId = extra.AlbumId;
            foreach (var requested in extra.Tracks) {
                var local = FindTrack(requested.MediaPath);
                if (requested.TrackNumber != local.Track) throw new InvalidDataException("Core track-number mapping changed.");
            }
            foreach (var media in copy.Media) Upload(FindTrack(media.MediaPath), media.TargetUrl);
            SendExtraInfo(extra.AlbumId);
            Broadcast(new MediaCopyStatusBroadcast { CopyId = copy.CopyId, CopyPercent = 100 });
        } catch (Exception error) {
            Console.Error.WriteLine("Transfer failed: " + error.Message);
            Broadcast(new MediaCopyStatusBroadcast { CopyId = copy.CopyId, CopyPercent = 0, FailureMessage = error.Message });
            done.Set();
        }
    }
    static bool MetadataMatches(LightAlbumMetadata m) {
        if (m == null || !SameText(m.Name, tracks[0].Album) || !SameText(m.ArtistName, tracks[0].Artist) || m.Tracks == null || m.Tracks.Count != tracks.Count)
            return false;
        foreach (var expected in tracks) {
            var actual = m.Tracks.FirstOrDefault(t => t.TrackNumber == expected.Track);
            if (actual == null || !SameText(actual.Name, expected.Title)) return false;
        }
        return true;
    }
    static void Approve(Sooid id) {
        if (!MetadataMatches(currentMetadata)) {
            Console.Error.WriteLine("Core metadata does not match staged album; approval refused."); done.Set(); return;
        }
        Console.WriteLine("METADATA_OK\t" + currentMetadata.ArtistName + "\t" + currentMetadata.Name + "\t" + currentMetadata.Tracks.Count);
        connection.Message.SendRequest(new ImportProjectApproveRequest { ProjectId = project, MediaId = id, ClobberDuplicatesByName = false });
    }
    static void State(Sooid id, ImportMediaStatus status, bool duplicate) {
        if (CancelRequested()) { result = 4; done.Set(); return; }
        Console.WriteLine("STATE\t" + id + "\t" + status + "\tduplicate=" + duplicate);
        if (duplicate && !duplicateSemanticsTest) { Console.WriteLine("CMDUPLICATE\tCore marked staged album duplicate"); done.Set(); return; }
        if (duplicate && duplicateSemanticsTest) Console.WriteLine("CMDUPLICATE_TEST\tApproving with ClobberDuplicatesByName=false");
        if (status == ImportMediaStatus.WaitingForApproval && Interlocked.Exchange(ref approved, 1) == 0) {
            connection.Message.SendRequest(new MusicProjectReapplyUserMetadataRequest { ProjectId = project, AlbumId = id },
                delegate(IMessage response, bool final) {
                    if (!final) return;
                    if (!(response is Sooloos.Msg.Common.SuccessResponse)) {
                        Console.Error.WriteLine("Could not reapply staged metadata: " + response); done.Set(); return;
                    }
                    ThreadPool.QueueUserWorkItem(delegate { Thread.Sleep(500); Approve(id); });
                });
        }
        if (status == ImportMediaStatus.Complete && Interlocked.Exchange(ref finalizing, 1) == 0)
            ThreadPool.QueueUserWorkItem(delegate {
                try { Verify(id); result = 0; }
                catch (Exception error) { Console.Error.WriteLine("Post-import verification failed: " + error.Message); }
                finally { done.Set(); }
            });
        if (status == ImportMediaStatus.Failed) { Console.Error.WriteLine("Core marked import failed."); done.Set(); }
    }
    static void Verify(Sooid id) {
        Console.WriteLine("CMPROGRESS\tVERIFY\t0\t" + tracks.Count + "\t0\t1\t" + ProgressText(tracks[0].Album)); Console.Out.Flush();
        var album = Request(connection, new GetAlbumRequest { AlbumId = id }) as Album;
        if (album == null) throw new InvalidOperationException("Imported album could not be read back from Core.");
        if (!SameText(album.ArtistName, tracks[0].Artist) || !SameText(album.AlbumName, tracks[0].Album) || album.Tracks.Count != tracks.Count)
            throw new InvalidOperationException("Imported album metadata does not match staging manifest.");
        foreach (var expected in tracks) {
            var actual = album.Tracks.FirstOrDefault(t => t.TrackNumber == expected.Track);
            if (actual == null || !SameText(actual.TrackName, expected.Title) || actual.FileInfo == null)
                throw new InvalidOperationException("Imported track mapping failed at track " + expected.Track + ".");
            if (actual.FileInfo.FileSize != expected.Size || actual.FileInfo.SampleRate != expected.Rate ||
                actual.FileInfo.BitsPerSample != expected.Bits || actual.FileInfo.ChannelCount != expected.Channels)
                throw new InvalidOperationException("Imported audio properties differ at track " + expected.Track + ".");
        }
        Console.WriteLine("CMVERIFIED\t" + album.AlbumId + "\t" + album.ArtistName + "\t" + album.AlbumName + "\t" + album.Tracks.Count);
        Console.WriteLine("CMPROGRESS\tVERIFY\t0\t" + tracks.Count + "\t1\t1\t" + ProgressText(tracks[0].Album)); Console.Out.Flush();
    }

    static void ProjectState(IMessage response, bool final) {
        var subscribed = response as ImportProjectSubscribeResponse;
        if (subscribed != null) {
            if (subscribed.ProjectData != null && subscribed.ProjectData.Media != null) {
                foreach (var media in subscribed.ProjectData.Media) {
                    if (media == null || media.MetadataPackage == null) continue;
                    var light = media.MetadataPackage.LightMetadata as LightAlbumMetadata;
                    if (light != null) currentMetadata = light;
                    Console.WriteLine("SUBSCRIBE_MEDIA\t" + media.MetadataPackage.MediaId + "\t" + media.Status + "\tduplicate=" + media.IsDuplicate + "\t" + (light == null ? "" : light.Name));
                    if (editionMode && Interlocked.Exchange(ref earlyReapplySent, 1) == 0) {
                        var id = media.MetadataPackage.MediaId;
                        connection.Message.SendRequest(new MusicProjectReapplyUserMetadataRequest { ProjectId = project, AlbumId = id },
                            delegate(IMessage m, bool end) {
                                if (end) Console.WriteLine("EARLY_REAPPLY\t" + m);
                            });
                    }
                }
            }
            return;
        }
        var update = response as ImportProjectUpdatedResponse;
        if (update == null) return;
        if (update.MediaUpdated != null) foreach (var m in update.MediaUpdated) {
            var light = m.LightMetadata as LightAlbumMetadata;
            if (light != null) currentMetadata = light;
        }
        if (update.MediaAdded != null) foreach (var m in update.MediaAdded) {
            var light = m.MetadataPackage.LightMetadata as LightAlbumMetadata;
            if (light != null) currentMetadata = light;
            State(m.MetadataPackage.MediaId, m.Status, m.IsDuplicate);
        }
        if (update.MediaStatusUpdated != null) foreach (var m in update.MediaStatusUpdated)
            State(m.MediaId, m.Status, m.IsDuplicate);
    }
    static MusicFileInfo[] MusicFiles() {
        return tracks.Select(t => new MusicFileInfo {
            FileInfo = new Sooloos.Msg.Import.FileInfo {
                MediaPath = t.Encoded, OriginalPath = t.Path, FileSize = t.Size, IsDirectory = false
            },
            ExtractedTags = Tags(t), CoverUrls = new string[0]
        }).ToArray();
    }
    static void CreateProject() {
        connection.Message.SendRequest(new CreateLooseFilesMusicProjectRequest {
            ImportDeviceId = device,
            CreateOptions = new[] { CreateOption.PreferUserMetadata, CreateOption.Private },
            MusicFiles = MusicFiles()
        }, delegate(IMessage message, bool last) {
            var created = message as ProjectCreatedResponse;
            if (created != null) {
                project = created.ProjectId; ownedProject = !created.ProjectAlreadyExists;
                Console.WriteLine("PROJECT\t" + project + "\tnew=" + (!created.ProjectAlreadyExists));
                if (created.ProjectAlreadyExists) { Console.WriteLine("CMDUPLICATE\tExisting import project"); done.Set(); return; }
                connection.Message.SendRequest(new ImportProjectSubscribeRequest { ProjectId = project }, ProjectState);
            }
            if (message is Sooloos.Msg.Common.ErrorResponse) {
                Console.WriteLine("PROJECT_ERROR\t" + message);
                if (message.ToString().IndexOf("Nothing to do", StringComparison.OrdinalIgnoreCase) >= 0) done.Set();
            }
            if (message is ProjectCreationCompletedResponse && project != Guid.Empty)
                Console.WriteLine("PROJECT_READY\t" + project);
        });
    }
    static void GroupProject() {
        connection.Message.SendRequest(new LooseMusicFilesMakeAlbumRequest {
            ProjectId = project,
            MediaPaths = tracks.Select(t => t.Encoded).ToArray(),
            CreateOptions = new[] { CreateOption.PreferUserMetadata, CreateOption.Private }
        }, delegate(IMessage message, bool final) {
            Console.WriteLine("GROUP\t" + message.GetType().Name + "\t" + message);
            if (final && !(message is Sooloos.Msg.Common.SuccessResponse)) done.Set();
        });
    }
    static void RegisterDevice() {
        connection.Message.SendRequest(new AuxDeviceConnectRequest {
            Info = new AuxDeviceInfo {
                DeviceId = device, Description = "ControlMac2026 batch import",
                Capabilities = new[] { Capabilities.Import }, ConfigurationType = ConfigurationType.Static
            }, PingSeconds = 20
        }, delegate(IMessage response, bool final) {
            var incoming = response as AuxDeviceMessageResponse;
            if (incoming != null) {
                var copy = incoming.Message as MediaCopyCommand;
                if (copy != null) ThreadPool.QueueUserWorkItem(delegate { Transfer(copy); });
                return;
            }
            if (response is AuxDeviceConnectResponse && Interlocked.Exchange(ref registered, 1) == 0) CreateProject();
        });
    }
    static void CleanupOwnedProject() {
        if (!ownedProject || project == Guid.Empty || connection == null) return;
        try {
            var removed = new ManualResetEvent(false);
            connection.Message.SendRequest(new ImportProjectRemoveRequest { ProjectId = project },
                delegate(IMessage m, bool final) {
                    Console.WriteLine("PROJECT_CLEANUP\t" + m);
                    if (final) removed.Set();
                });
            if (!removed.WaitOne(5000)) Console.Error.WriteLine("Cleanup unconfirmed for import project " + project);
        } catch (Exception error) { Console.Error.WriteLine("Cleanup failed for import project " + project + ": " + error.Message); }
    }
    public static int Main(string[] args) {
        if ((args.Length != 3 && args.Length != 4) || (args[0] != "--import" && args[0] != "--import-edition" && args[0] != "--duplicate-semantics-test" && args[0] != "--check")) {
            Console.Error.WriteLine("Usage: BatchImportTool --check|--import|--import-edition CORE_HOST manifest.tsv [cancel-file]"); return 2;
        }
        try {
            editionMode = args[0] == "--import-edition";
            duplicateSemanticsTest = args[0] == "--duplicate-semantics-test";
            cancelPath = args.Length == 4 ? args[3] : null;
            host = args[1]; tracks = LoadManifest(args[2]); CheckCancel(); AnalyzeAlbum(); CheckCancel();
            BrokerProbe.Initialize(); connection = new Connection(host); device = new Sooid(24, Guid.NewGuid());
            var ready = new ManualResetEvent(false);
            connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
                if (status.ToString() == "Connected" && Interlocked.Exchange(ref connected, 1) == 0) ready.Set();
            };
            connection.Connect();
            if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");
            bool duplicate = ExistingExactDuplicate();
            if (args[0] == "--check") { Console.WriteLine(duplicate ? "CHECK_DUPLICATE" : "CHECK_CLEAR"); return duplicate ? 3 : 0; }
            if (duplicate && !duplicateSemanticsTest) { Console.WriteLine("IMPORT_SKIPPED_DUPLICATE"); return 3; }
            if (duplicate && duplicateSemanticsTest) Console.WriteLine("PREFLIGHT_DUPLICATE_TEST\tcontinuing only for semantics test");
            RegisterDevice();
            using (var ping = new Timer(delegate(object state) {
                if (registered != 0) connection.Message.SendRequest(new AuxDevicePingRequest { DeviceId = device });
            }, null, 5000, 5000)) {
                var deadline = DateTime.UtcNow.AddMinutes(10);
                while (!done.WaitOne(250)) {
                    if (CancelRequested()) { result = 4; done.Set(); break; }
                    if (DateTime.UtcNow >= deadline) throw new TimeoutException("Import timed out; inspect project " + project + " before retrying.");
                }
            }
            if (result == 0) Console.WriteLine("CORE CONFIRMED BATCH IMPORT COMPLETE");
            else Console.WriteLine("IMPORT NOT CONFIRMED COMPLETE; project=" + project);
            return result;
        } catch (OperationCanceledException) { result = 4; Console.WriteLine("IMPORT_CANCELLED"); return 4; }
        catch (Exception error) { Console.Error.WriteLine("CMERROR\t" + error.Message); return 1; }
        finally { if (connection != null) { if (result != 0) CleanupOwnedProject(); connection.Disconnect(); } }
    }
}
