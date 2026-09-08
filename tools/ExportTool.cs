using System;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using Sooloos.Broker;
using Sooloos.Msg.Export;
using Sooloos.Msg.Music;
using ExportAlbumRequest = Sooloos.Msg.Music.Internal.ExportAlbumRequest;

internal static class ExportTool {
    static string Tool(string name) {
        string root = Environment.GetEnvironmentVariable("CONTROLMAC_TOOL_DIR");
        if (!String.IsNullOrEmpty(root)) {
            string bundled = Path.Combine(root, name);
            if (File.Exists(bundled)) return bundled;
        }
        return name;
    }

    static Connection connection;
    static string cancelPath;
    static bool CancelRequested() { return !String.IsNullOrEmpty(cancelPath) && File.Exists(cancelPath); }
    static void CheckCancel() { if (CancelRequested()) throw new OperationCanceledException("Export cancelled."); }
    static IMessage Request(IMessage request) {
        IMessage response = null;
        var done = new ManualResetEvent(false);
        connection.Message.SendRequest(request, delegate(IMessage m, bool final) {
            response = m; if (final) done.Set();
        });
        if (!done.WaitOne(30000)) throw new TimeoutException("Core export request timed out.");
        return response;
    }
    static Sooid Id(string text) {
        var bits = text.Split(':');
        return new Sooid(1, Guid.Parse(bits[bits.Length - 1]));
    }
    static Sooloos.Msg.Music.Album GetAlbum(string text) {
        var a = Request(new GetAlbumRequest { AlbumId = Id(text) }) as Sooloos.Msg.Music.Album;
        if (a == null) throw new InvalidOperationException("Album not found.");
        return a;
    }
    static string Safe(string value) {
        var s = value ?? "";
        foreach (char c in Path.GetInvalidFileNameChars()) s = s.Replace(c, '-');
        s = s.Replace('/', '-').Replace(':', '-');
        s = Regex.Replace(s, @"\s+", " ").Trim();
        return s.Length == 0 ? "Untitled" : s;
    }
    static Dictionary<int,Sooloos.Msg.Durable.MediaFile> MediaMap(ExportResponse r) {
        var map = new Dictionary<int,Sooloos.Msg.Durable.MediaFile>();
        foreach (var pkg in r.MetadataPackages)
        foreach (var item in pkg.Items)
        foreach (var f in item.MediaFiles) {
            var m = Regex.Match(f.Name ?? "", @"^track(\d+)\.", RegexOptions.IgnoreCase);
            if (m.Success) map[int.Parse(m.Groups[1].Value)] = f;
        }
        return map;
    }
    static void Download(string url, string path, long expected, int track, int count, string title) {
        var req = (HttpWebRequest)WebRequest.Create(url);
        using (var resp = (HttpWebResponse)req.GetResponse())
        using (var input = resp.GetResponseStream())
        using (var output = File.Create(path)) {
            var buffer = new byte[1024 * 256]; long total = 0; int n;
            while ((n = input.Read(buffer, 0, buffer.Length)) > 0) {
                CheckCancel(); output.Write(buffer, 0, n); total += n;
                Console.WriteLine("CMEXPROGRESS\tDOWNLOAD\t" + track + "\t" + count + "\t" + total + "\t" + expected + "\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(title ?? "")));
            }
            if (expected > 0 && total != expected) throw new IOException("Downloaded size mismatch for track " + track + ".");
        }
    }
    static int RunProcess(string exe, string args) {
        var p = new Process();
        p.StartInfo.FileName = exe; p.StartInfo.Arguments = args;
        p.StartInfo.UseShellExecute = false; p.StartInfo.RedirectStandardError = true;
        p.Start();
        while (!p.WaitForExit(200)) { if (CancelRequested()) { try { p.Kill(); } catch {} throw new OperationCanceledException("Export cancelled."); } }
        string err = p.StandardError.ReadToEnd();
        if (p.ExitCode != 0) throw new InvalidOperationException(Path.GetFileName(exe) + " failed: " + err);
        return p.ExitCode;
    }
    static string Q(string s) { return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\""; }
    static Sooloos.Msg.Durable.MediaFile FindMediaFile(ExportResponse r, string name) {
        foreach (var pkg in r.MetadataPackages)
        foreach (var item in pkg.Items)
        foreach (var f in item.MediaFiles)
            if (String.Equals(f.Name, name, StringComparison.OrdinalIgnoreCase)) return f;
        return null;
    }
    static string Capture(string exe, string args) {
        var p = new Process();
        p.StartInfo.FileName = exe; p.StartInfo.Arguments = args;
        p.StartInfo.UseShellExecute = false; p.StartInfo.RedirectStandardOutput = true; p.StartInfo.RedirectStandardError = true;
        p.Start(); string text = p.StandardOutput.ReadToEnd(); string err = p.StandardError.ReadToEnd(); p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException(Path.GetFileName(exe) + " failed: " + err);
        return text;
    }
    static void Verify(string path, Sooloos.Msg.Music.Track t) {
        string text = Capture(Tool("ffprobe"), "-v error -select_streams a:0 -show_entries stream=sample_rate,bits_per_raw_sample,channels -of default=noprint_wrappers=1 " + Q(path));
        var values = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in text.Split('\n')) { int eq = line.IndexOf('='); if (eq > 0) values[line.Substring(0,eq)] = line.Substring(eq+1).Trim(); }
        int rate = values.ContainsKey("sample_rate") ? int.Parse(values["sample_rate"]) : 0;
        int bits = values.ContainsKey("bits_per_raw_sample") && values["bits_per_raw_sample"].Length > 0 ? int.Parse(values["bits_per_raw_sample"]) : 0;
        int channels = values.ContainsKey("channels") ? int.Parse(values["channels"]) : 0;
        if (t.FileInfo.SampleRate.HasValue && rate != t.FileInfo.SampleRate.Value) throw new IOException("Sample-rate changed on export.");
        if (t.FileInfo.BitsPerSample.HasValue && bits > 0 && bits != t.FileInfo.BitsPerSample.Value) throw new IOException("Bit depth changed on export.");
        if (t.FileInfo.ChannelCount.HasValue && channels != t.FileInfo.ChannelCount.Value) throw new IOException("Channel count changed on export.");
    }
    static void TagFlac(string path, Sooloos.Msg.Music.Album a, Sooloos.Msg.Music.Track t, string cover) {
        var args = new StringBuilder("--remove-all-tags ");
        args.Append(Q("--set-tag=ARTIST=" + (t.ArtistName ?? a.ArtistName))).Append(' ');
        args.Append(Q("--set-tag=ALBUMARTIST=" + a.ArtistName)).Append(' ');
        args.Append(Q("--set-tag=ALBUM=" + a.AlbumName)).Append(' ');
        args.Append(Q("--set-tag=TITLE=" + t.TrackName)).Append(' ');
        args.Append(Q("--set-tag=TRACKNUMBER=" + t.TrackNumber)).Append(' ');
        args.Append(Q("--set-tag=DISCNUMBER=" + Math.Max(1, a.MediaNumber))).Append(' ');
        if (!String.IsNullOrEmpty(cover) && File.Exists(cover)) args.Append(Q("--import-picture-from=" + cover)).Append(' ');
        args.Append(Q(path));
        RunProcess(Tool("metaflac"), args.ToString());
    }
    static void MakeOutput(string raw, string output, string format, Sooloos.Msg.Music.Album a, Sooloos.Msg.Music.Track t, string cover) {
        string ext = Path.GetExtension(raw).ToLowerInvariant();
        if (format == "flac" && ext == ".flac") {
            File.Copy(raw, output, true); TagFlac(output, a, t, cover); return;
        }
        var args = new StringBuilder("-hide_banner -loglevel error -y -i ").Append(Q(raw)).Append(' ');
        if (format == "alac" && !String.IsNullOrEmpty(cover) && File.Exists(cover)) args.Append("-i ").Append(Q(cover)).Append(" -map 0:a:0 -map 1:v:0 ");
        else args.Append("-map 0:a:0 ");
        args.Append("-map_metadata -1 ");
        args.Append(format == "alac" ? "-c:a alac " : "-c:a flac -compression_level 8 ");
        if (format == "alac" && !String.IsNullOrEmpty(cover) && File.Exists(cover)) args.Append("-c:v mjpeg -disposition:v:0 attached_pic ");
        args.Append("-metadata ").Append(Q("artist=" + (t.ArtistName ?? a.ArtistName))).Append(' ');
        args.Append("-metadata ").Append(Q("album_artist=" + a.ArtistName)).Append(' ');
        args.Append("-metadata ").Append(Q("album=" + a.AlbumName)).Append(' ');
        args.Append("-metadata ").Append(Q("title=" + t.TrackName)).Append(' ');
        args.Append("-metadata ").Append(Q("track=" + t.TrackNumber)).Append(' ');
        args.Append("-metadata ").Append(Q("disc=" + Math.Max(1, a.MediaNumber))).Append(' ');
        args.Append(Q(output));
        RunProcess(Tool("ffmpeg"), args.ToString());
        if (format == "flac") TagFlac(output, a, t, cover);
    }
    static void Plan(Sooloos.Msg.Music.Album a, ExportResponse prepared) {
        var media = MediaMap(prepared);
        Console.WriteLine("CMEXPORTPLAN\t" + a.AlbumId + "\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(a.ArtistName)) + "\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(a.AlbumName)) + "\t" + a.Tracks.Count);
        foreach (var t in a.Tracks) {
            Sooloos.Msg.Durable.MediaFile f;
            if (!media.TryGetValue(t.TrackNumber, out f)) throw new InvalidDataException("Missing media file for track " + t.TrackNumber);
            Console.WriteLine("CMEXPORTTRACK\t" + t.TrackNumber + "\t" + t.TrackId + "\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(t.TrackName)) + "\t" + f.Name + "\t" + f.Size + "\t" + f.Url + "\t" + t.FileInfo.SampleRate + "\t" + t.FileInfo.BitsPerSample + "\t" + t.FileInfo.ChannelCount);
        }
    }
    static void ExportFolder(Sooloos.Msg.Music.Album a, ExportResponse prepared, string format, string destinationRoot, string folderSuffix) {
        if (format != "flac" && format != "alac") throw new ArgumentException("Format must be flac or alac.");
        var media = MediaMap(prepared);
        string folderName = Safe(a.ArtistName + " - " + a.AlbumName + (a.MediaCount > 1 ? " - Disc " + a.MediaNumber : ""));
        if (!String.IsNullOrEmpty(folderSuffix)) folderName += " [" + Safe(folderSuffix) + "]";
        string dest = Path.Combine(destinationRoot, folderName);
        Directory.CreateDirectory(dest);
        string temp = Path.Combine(Path.GetTempPath(), "controlmac-export-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temp);
        string coverPath = null;
        try {
            var cover = FindMediaFile(prepared, "cover.jpg");
            if (cover != null) {
                coverPath = Path.Combine(dest, "cover.jpg");
                Download(cover.Url, coverPath, cover.Size, 0, a.Tracks.Count, "cover");
            }
            int count = a.Tracks.Count;
            foreach (var t in a.Tracks) {
                CheckCancel();
                Sooloos.Msg.Durable.MediaFile f;
                if (!media.TryGetValue(t.TrackNumber, out f)) throw new InvalidDataException("Missing media file for track " + t.TrackNumber);
                string sourceExt = Path.GetExtension(f.Name);
                string raw = Path.Combine(temp, String.Format("track{0:00}{1}", t.TrackNumber, sourceExt));
                Download(f.Url, raw, f.Size, t.TrackNumber, count, t.TrackName);
                string output = Path.Combine(dest, String.Format("{0:00} {1}.{2}", t.TrackNumber, Safe(t.TrackName), format == "alac" ? "m4a" : "flac"));
                Console.WriteLine("CMEXPROGRESS\tCONVERT\t" + t.TrackNumber + "\t" + count + "\t0\t1\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(t.TrackName)));
                try { MakeOutput(raw, output, format, a, t, coverPath); Verify(output, t); }
                catch { if (CancelRequested()) { try { File.Delete(output); } catch {} } throw; }
                Console.WriteLine("CMEXPROGRESS\tVERIFY\t" + t.TrackNumber + "\t" + count + "\t1\t1\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(t.TrackName)));
            }
            Console.WriteLine("CMEXPORTDONE\t" + dest);
        } finally { try { Directory.Delete(temp, true); } catch {} }
    }
    static string CueText(string s) { return (s ?? "").Replace("\"", "'"); }
    static string MsF(long sector) {
        long minutes = sector / (75 * 60); sector %= (75 * 60);
        long seconds = sector / 75; long frames = sector % 75;
        return String.Format("{0:00}:{1:00}:{2:00}", minutes, seconds, frames);
    }
    static void ExportCDImage(Sooloos.Msg.Music.Album a, ExportResponse prepared, string destinationRoot) {
        var media = MediaMap(prepared);
        string folderName = Safe(a.ArtistName + " - " + a.AlbumName + (a.MediaCount > 1 ? " - Disc " + a.MediaNumber : "") + " - CD-A");
        string dest = Path.Combine(destinationRoot, folderName); Directory.CreateDirectory(dest);
        string baseName = Safe(a.ArtistName + " - " + a.AlbumName);
        string binPath = Path.Combine(dest, baseName + ".bin"); string cuePath = Path.Combine(dest, baseName + ".cue");
        string temp = Path.Combine(Path.GetTempPath(), "controlmac-cda-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(temp);
        try {
            var cue = new StringBuilder();
            cue.AppendLine("PERFORMER \"" + CueText(a.ArtistName) + "\"");
            cue.AppendLine("TITLE \"" + CueText(a.AlbumName) + "\"");
            cue.AppendLine("FILE \"" + Path.GetFileName(binPath) + "\" BINARY");
            long sectors = 0; int count = a.Tracks.Count;
            using (var bin = File.Create(binPath)) {
                foreach (var t in a.Tracks) {
                    CheckCancel(); Sooloos.Msg.Durable.MediaFile f;
                    if (!media.TryGetValue(t.TrackNumber, out f)) throw new InvalidDataException("Missing media file for track " + t.TrackNumber);
                    string raw = Path.Combine(temp, String.Format("track{0:00}{1}", t.TrackNumber, Path.GetExtension(f.Name)));
                    string pcm = Path.Combine(temp, String.Format("track{0:00}.pcm", t.TrackNumber));
                    Download(f.Url, raw, f.Size, t.TrackNumber, count, t.TrackName);
                    Console.WriteLine("CMEXPROGRESS\tCONVERT\t" + t.TrackNumber + "\t" + count + "\t0\t1\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(t.TrackName)));
                    RunProcess(Tool("ffmpeg"), "-hide_banner -loglevel error -y -i " + Q(raw) + " -map 0:a:0 -af " + Q("aresample=44100:resampler=swr:filter_size=64:phase_shift=10:exact_rational=1:dither_method=triangular_hp") + " -ar 44100 -ac 2 -c:a pcm_s16le -f s16le " + Q(pcm));
                    long start = sectors; long length = new FileInfo(pcm).Length; long padded = ((length + 2351) / 2352) * 2352;
                    using (var input = File.OpenRead(pcm)) { input.CopyTo(bin); }
                    for (long pad = length; pad < padded; pad++) bin.WriteByte(0);
                    sectors += padded / 2352;
                    cue.AppendLine(String.Format("  TRACK {0:00} AUDIO", t.TrackNumber));
                    cue.AppendLine("    TITLE \"" + CueText(t.TrackName) + "\"");
                    cue.AppendLine("    PERFORMER \"" + CueText(t.ArtistName ?? a.ArtistName) + "\"");
                    cue.AppendLine("    INDEX 01 " + MsF(start));
                    Console.WriteLine("CMEXPROGRESS\tVERIFY\t" + t.TrackNumber + "\t" + count + "\t1\t1\t" + Convert.ToBase64String(Encoding.UTF8.GetBytes(t.TrackName)));
                }
            }
            File.WriteAllText(cuePath, cue.ToString(), Encoding.UTF8);
            var cover = FindMediaFile(prepared, "cover.jpg"); if (cover != null) Download(cover.Url, Path.Combine(dest, "cover.jpg"), cover.Size, 0, a.Tracks.Count, "cover");
            Console.WriteLine("CMEXPORTDONE\t" + dest);
        } catch {
            if (CancelRequested()) { try { File.Delete(binPath); } catch {} try { File.Delete(cuePath); } catch {} }
            throw;
        } finally { try { Directory.Delete(temp, true); } catch {} }
    }

    static int Run(string[] args) {
        if (args.Length < 3) { Console.Error.WriteLine("Usage: ExportTool plan HOST ALBUM_ID | ExportTool folder HOST ALBUM_ID flac|alac DEST"); return 2; }
        string command = args[0], host = args[1], albumId = args[2];
        cancelPath = command == "folder" && args.Length >= 6 ? args[5] : (command == "backup-one" && args.Length >= 5 ? args[4] : (command == "cda" && args.Length >= 5 ? args[4] : null));
        CheckCancel();
        BrokerProbe.Initialize(); connection = new Connection(host);
        var ready = new ManualResetEvent(false);
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus s) { if (s.ToString() == "Connected") ready.Set(); };
        connection.Connect(); if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");
        var album = GetAlbum(albumId);
        var prepared = Request(new ExportAlbumRequest { MediaId = album.AlbumId }) as ExportResponse;
        if (prepared == null || prepared.Failures.Count > 0) throw new InvalidOperationException("Core could not prepare album for export.");
        if (command == "plan") Plan(album, prepared);
        else if (command == "folder" && (args.Length == 5 || args.Length == 6)) ExportFolder(album, prepared, args[3].ToLowerInvariant(), args[4], null);
        else if (command == "backup-one" && args.Length == 5) {
            var idText = album.AlbumId.ToString(); var shortId = idText.Length > 8 ? idText.Substring(idText.Length - 8) : idText;
            ExportFolder(album, prepared, "flac", args[3], album.Tracks.Count + " tracks " + shortId);
        }
        else if (command == "cda" && args.Length == 5) ExportCDImage(album, prepared, args[3]);
        else return 2;
        return 0;
    }
    public static int Main(string[] args) {
        try { return Run(args); }
        catch (OperationCanceledException) { Console.WriteLine("CMEXPORTCANCELLED"); return 4; }
        catch (Exception e) { Console.Error.WriteLine("CMERROR\t" + e.Message); return 1; }
        finally { if (connection != null) connection.Disconnect(); }
    }
}
