// Reads native FLAC metadata without the original 32-bit tagtool.
// The only network operation is a library search. No import is created.
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Threading;
using Sooloos.Broker;
using Sooloos.Msg.Import;

internal sealed class FlacMetadata
{
    public readonly List<MusicFileTag> Tags = new List<MusicFileTag>();
    public int Rate, Channels, Bits;
    public long Samples;
    public string Get(string key) {
        foreach (var t in Tags) if (String.Equals(t.Name, key, StringComparison.OrdinalIgnoreCase)) return t.Value;
        return "";
    }
    static byte[] Read(BinaryReader r, int length) {
        byte[] b = r.ReadBytes(length);
        if (b.Length != length) throw new InvalidDataException("Truncated FLAC metadata.");
        return b;
    }
    public static FlacMetadata Load(string path) {
        var m = new FlacMetadata();
        bool first = true, comments = false;
        long budget = 64 * 1024 * 1024;
        using (var r = new BinaryReader(File.OpenRead(path))) {
            if (Encoding.ASCII.GetString(Read(r, 4)) != "fLaC") throw new InvalidDataException("Not native FLAC.");
            while (true) {
                byte[] h = Read(r, 4);
                int type = h[0] & 127, n = (h[1] << 16) | (h[2] << 8) | h[3];
                budget -= n + 4;
                if (budget < 0 || type == 127) throw new InvalidDataException("Invalid or excessive metadata.");
                if (first && (type != 0 || n != 34)) throw new InvalidDataException("Missing STREAMINFO.");
                byte[] b = Read(r, n);
                if (type == 0) {
                    if (!first || n != 34) throw new InvalidDataException("Invalid STREAMINFO.");
                    ulong packed = 0;
                    for (int i = 10; i < 18; ++i) packed = (packed << 8) | b[i];
                    m.Rate = (int)(packed >> 44); m.Channels = (int)((packed >> 41) & 7) + 1;
                    m.Bits = (int)((packed >> 36) & 31) + 1; m.Samples = (long)(packed & 0xfffffffffUL);
                    if (m.Rate == 0 || m.Samples == 0) throw new InvalidDataException("Unknown audio duration.");
                } else if (type == 4) {
                    if (comments) throw new InvalidDataException("Duplicate comment block.");
                    comments = true;
                    using (var c = new BinaryReader(new MemoryStream(b))) {
                        uint vendor = c.ReadUInt32();
                        if (vendor > b.Length) throw new InvalidDataException("Invalid vendor length.");
                        Read(c, (int)vendor);
                        uint count = c.ReadUInt32();
                        if (count > 10000) throw new InvalidDataException("Excessive tag count.");
                        for (uint i = 0; i < count; ++i) {
                            uint len = c.ReadUInt32();
                            if (len > b.Length) throw new InvalidDataException("Invalid tag length.");
                            string tag = new UTF8Encoding(false, true).GetString(Read(c, (int)len));
                            int split = tag.IndexOf('=');
                            if (split <= 0) throw new InvalidDataException("Invalid tag.");
                            m.Tags.Add(new MusicFileTag { Name = tag.Substring(0, split), Value = tag.Substring(split + 1) });
                        }
                        if (c.BaseStream.Position != b.Length) throw new InvalidDataException("Trailing comment bytes.");
                    }
                }
                first = false;
                if ((h[0] & 128) != 0) break;
            }
        }
        m.Tags.RemoveAll(t => t.Name == "length" || t.Name == "lengthms" || t.Name == "samplerate");
        m.Tags.Add(new MusicFileTag { Name = "length", Value = (m.Samples / m.Rate).ToString(System.Globalization.CultureInfo.InvariantCulture) });
        m.Tags.Add(new MusicFileTag { Name = "lengthms", Value = (m.Samples * 1000 / m.Rate).ToString(System.Globalization.CultureInfo.InvariantCulture) });
        m.Tags.Add(new MusicFileTag { Name = "samplerate", Value = m.Rate.ToString(System.Globalization.CultureInfo.InvariantCulture) });
        return m;
    }
}

internal static class ImportPreflight
{
    public static int Main(string[] args) {
        if (args.Length != 2) { Console.Error.WriteLine("Usage: ImportPreflight CORE_HOST TRACK.flac"); return 2; }
        try {
            var metadata = FlacMetadata.Load(args[1]);
            Console.WriteLine("Track: " + metadata.Get("TITLE"));
            Console.WriteLine("Album: " + metadata.Get("ALBUM") + "; artist: " + metadata.Get("ARTIST"));
            Console.WriteLine("Audio: " + metadata.Rate + " Hz / " + metadata.Bits + " bits / " + metadata.Channels + " channels");
            if (metadata.Get("ALBUM").Length == 0) throw new InvalidDataException("Album tag required for duplicate search.");
            BrokerProbe.Initialize();
            var done = new ManualResetEvent(false);
            var connection = new Connection(args[0]);
            int sent = 0, result = 1;
            connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
                if (status.ToString() != "Connected" || Interlocked.Exchange(ref sent, 1) != 0) return;
                connection.Message.SendRequest(new Sooloos.Msg.Music.FastSearchRequest {
                    Substring = metadata.Get("ALBUM"), MaxAlbumCount = 100, MaxTrackCount = 100
                }, delegate(IMessage response, bool final) {
                    var found = response as Sooloos.Msg.Music.FastSearchResponse;
                    if (found != null) {
                        Console.WriteLine("Search result: " + found);
                        result = 0;
                    } else Console.WriteLine("Unexpected response: " + response);
                    if (final) done.Set();
                });
            };
            try {
                connection.Connect();
                if (!done.WaitOne(20000)) { Console.Error.WriteLine("Search timed out."); result = 1; }
            } finally { connection.Disconnect(); }
            return result;
        } catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }
}
