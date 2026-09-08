using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using Sooloos.Broker;
using Sooloos.Msg.Music;

internal static class LibraryTool {
    static Connection connection;
    static string B64(string s) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(s ?? "")); }
    static Sooid Id(string text, int type) {
        var bits = text.Split(':');
        return new Sooid((byte)type, Guid.Parse(bits[bits.Length - 1]));
    }
    static IMessage Request(IMessage request) {
        IMessage response = null;
        var done = new ManualResetEvent(false);
        connection.Message.SendRequest(request, delegate(IMessage m, bool final) {
            response = m;
            if (final) done.Set();
        });
        if (!done.WaitOne(20000)) throw new TimeoutException("Core request timed out.");
        return response;
    }
    static void NeedSuccess(IMessage message) {
        if (!(message is Sooloos.Msg.Common.SuccessResponse))
            throw new InvalidOperationException("Core rejected change: " + message);
    }
    static void ListAlbums(string query) {
        var r = Request(new FastSearchRequest {
            Substring = query ?? "", MaxAlbumCount = 10000, MaxTrackCount = 0
        }) as FastSearchResponse;
        if (r == null) throw new InvalidOperationException("Unexpected library response.");
        foreach (var a in r.Albums) {
            Console.WriteLine("CMALBUM\t" + a.AlbumId + "\t" + B64(a.ArtistName) + "\t" + B64(a.AlbumName) +
                "\t" + a.MediaNumber + "\t" + a.MediaCount + "\t" + B64(a.CoverUrl) + "\t" + a.Quality);
        }
    }
    static void ScanLibrary() {
        var search = Request(new FastSearchRequest { Substring = "", MaxAlbumCount = 10000, MaxTrackCount = 0 }) as FastSearchResponse;
        if (search == null) throw new InvalidOperationException("Could not enumerate library.");
        var ids = new List<Sooid>();
        foreach (var item in search.Albums) ids.Add(item.AlbumId);
        Console.WriteLine("CMSCAN\tBEGIN\t" + ids.Count);
        const int batchSize = 64;
        for (int start = 0; start < ids.Count; start += batchSize) {
            int count = Math.Min(batchSize, ids.Count - start);
            var batch = ids.GetRange(start, count);
            var list = Request(new GetAlbumsRequest { AlbumIds = batch }) as AlbumList;
            if (list == null) throw new InvalidOperationException("Bulk album read failed at " + start + ".");
            foreach (var a in list.Albums) {
                Console.WriteLine("CMCACHEALBUM\t" + a.AlbumId + "\t" + a.ArtistId + "\t" + B64(a.ArtistName) + "\t" + B64(a.AlbumName) +
                    "\t" + a.MediaNumber + "\t" + a.MediaCount + "\t" + B64(a.CoverUrl) + "\t" + a.HasRealCover + "\t" + a.Quality +
                    "\t" + a.Rating + "\t" + B64(a.ImportDate == null ? "" : a.ImportDate.ToString()) + "\t" + B64(a.ReleaseDate == null ? "" : a.ReleaseDate.ToString()) + "\t" + a.Tracks.Count);
                foreach (var t in a.Tracks) {
                    Console.WriteLine("CMCACHETRACK\t" + a.AlbumId + "\t" + t.TrackId + "\t" + t.TrackNumber + "\t" + B64(t.TrackName) +
                        "\t" + B64(t.ArtistName) + "\t" + t.Length + "\t" + t.FileInfo.FileSize + "\t" + t.FileInfo.FileType +
                        "\t" + t.FileInfo.SampleRate + "\t" + t.FileInfo.BitsPerSample + "\t" + t.FileInfo.ChannelCount + "\t" + t.FileInfo.Bitrate);
                }
            }
            Console.WriteLine("CMSCAN\tPROGRESS\t" + Math.Min(start + count, ids.Count) + "\t" + ids.Count);
        }
        Console.WriteLine("CMSCAN\tEND\t" + ids.Count);
    }

    static Album GetAlbum(string id) {
        var r = Request(new GetAlbumRequest { AlbumId = Id(id, 1) }) as Album;
        if (r == null) throw new InvalidOperationException("Album not found.");
        return r;
    }
    static void ShowAlbum(string id) {
        var a = GetAlbum(id);
        Console.WriteLine("CMDETAIL\t" + a.AlbumId + "\t" + B64(a.ArtistName) + "\t" + B64(a.AlbumName) +
            "\t" + B64(a.CoverUrl) + "\t" + a.MediaNumber + "\t" + a.MediaCount + "\t" + a.Quality + "\t" + a.Tracks.Count);
        foreach (var t in a.Tracks) {
            Console.WriteLine("CMTRACK\t" + t.TrackId + "\t" + t.TrackNumber + "\t" + B64(t.TrackName) +
                "\t" + t.Length + "\t" + t.FileInfo.FileSize + "\t" + t.FileInfo.FileType + "\t" + t.FileInfo.SampleRate + "\t" + t.FileInfo.BitsPerSample);
        }
    }
    static void RenameAlbum(string id, string name) {
        var before = GetAlbum(id);
        NeedSuccess(Request(new AlbumEditNameRequest { AlbumId = before.AlbumId, Name = name }));
        var after = GetAlbum(id);
        if (after.AlbumName != name) throw new InvalidOperationException("Album rename did not persist.");
        Console.WriteLine("CMOK\talbum-name\t" + after.AlbumId + "\t" + B64(after.AlbumName));
    }
    static void RenameTrack(string id, string name) {
        var trackId = Id(id, 3);
        NeedSuccess(Request(new TrackEditNameRequest { TrackId = trackId, Name = name }));
        Console.WriteLine("CMOK\ttrack-name\t" + trackId + "\t" + B64(name));
    }
    static void SetCover(string id, string path) {
        var album = GetAlbum(id);
        var data = File.ReadAllBytes(path);
        if (data.Length < 32 || data.Length > 20 * 1024 * 1024)
            throw new InvalidDataException("Cover image size is invalid.");
        bool jpeg = data[0] == 0xff && data[1] == 0xd8;
        bool png = data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47;
        if (!jpeg && !png) throw new InvalidDataException("Cover must be JPEG or PNG.");
        var request = new AlbumEditCoverImageWithDataRequest { AlbumIds = new[] { album.AlbumId }, CoverImageData = data };
        NeedSuccess(Request(request));
        Console.WriteLine("CMOK\tcover\t" + album.AlbumId);
    }
    static void DeleteAlbum(string id, string expectedArtist, string expectedName, int expectedTracks, int expectedMediaNumber, int expectedMediaCount) {
        var album = GetAlbum(id);
        if (album.ArtistName != expectedArtist || album.AlbumName != expectedName || album.Tracks.Count != expectedTracks ||
            album.MediaNumber != expectedMediaNumber || album.MediaCount != expectedMediaCount)
            throw new InvalidOperationException("Delete guard failed; album changed since it was displayed. Refresh and review it again.");
        NeedSuccess(Request(new DeleteAlbumsRequest { AlbumOrGroupIds = new[] { album.AlbumId } }));
        Console.WriteLine("CMOK\tdeleted\t" + album.AlbumId);
    }
    static int Run(string[] args) {
        if (args.Length < 2) return 2;
        string command = args[0], host = args[1];
        BrokerProbe.Initialize();
        connection = new Connection(host);
        var ready = new ManualResetEvent(false);
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus s) {
            if (s.ToString() == "Connected") ready.Set();
        };
        connection.Connect();
        if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");
        if (command == "scan") ScanLibrary();
        else if (command == "list") ListAlbums(args.Length > 2 ? args[2] : "");
        else if (command == "album" && args.Length == 3) ShowAlbum(args[2]);
        else if (command == "rename-album" && args.Length == 4) RenameAlbum(args[2], args[3]);
        else if (command == "rename-track" && args.Length == 4) RenameTrack(args[2], args[3]);
        else if (command == "cover" && args.Length == 4) SetCover(args[2], args[3]);
        else if (command == "delete-album" && args.Length == 8) DeleteAlbum(args[2], args[3], args[4], int.Parse(args[5]), int.Parse(args[6]), int.Parse(args[7]));
        else return 2;
        return 0;
    }
    public static int Main(string[] args) {
        try { return Run(args); }
        catch (Exception error) {
            Console.Error.WriteLine("CMERROR\t" + error.Message);
            return 1;
        }
        finally {
            if (connection != null) connection.Disconnect();
        }
    }
}
