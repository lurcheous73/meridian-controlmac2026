using System;
using System.Threading;
using Sooloos.Broker;

internal static class LibraryProbe {
    public static int Main(string[] args) {
        if (args.Length != 1) return 2;
        BrokerProbe.Initialize();
        var done = new ManualResetEvent(false);
        var connection = new Connection(args[0]);
        int result = 1;
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
            if (status.ToString() != "Connected") return;
            connection.Message.SendRequest(new Sooloos.Msg.Music.FastSearchRequest {
                Substring = "", MaxAlbumCount = 10000, MaxTrackCount = 0
            }, delegate(IMessage message, bool final) {
                var response = message as Sooloos.Msg.Music.FastSearchResponse;
                if (response != null) {
                    foreach (var a in response.Albums) {
                        Console.WriteLine("CMALBUM\t" + a.AlbumId + "\t" + Clean(a.ArtistName) + "\t" + Clean(a.AlbumName) +
                            "\t" + a.MediaNumber + "\t" + a.MediaCount + "\t" + Clean(a.CoverUrl) + "\t" + a.Quality);
                    }
                    result = 0;
                }
                if (final) done.Set();
            });
        };
        try { connection.Connect(); if (!done.WaitOne(30000)) return 1; return result; }
        finally { connection.Disconnect(); }
    }
    static string Clean(string s) { return (s ?? "").Replace("\t", " ").Replace("\r", " ").Replace("\n", " "); }
}
