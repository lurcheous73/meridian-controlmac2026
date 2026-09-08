using System;
using System.Threading;
using Sooloos.Broker;
using Sooloos.Msg.Export;
using Sooloos.Msg.Music.Internal;

internal static class ExportProbe {
    static IMessage Request(Connection c, IMessage request) {
        IMessage response = null;
        var done = new ManualResetEvent(false);
        c.Message.SendRequest(request, delegate(IMessage m, bool final) {
            response = m;
            if (final) done.Set();
        });
        if (!done.WaitOne(20000)) throw new TimeoutException("Core export request timed out.");
        return response;
    }

    static Sooid Id(string text) {
        var bits = text.Split(':');
        return new Sooid(1, Guid.Parse(bits[bits.Length - 1]));
    }

    public static int Main(string[] args) {
        if (args.Length != 2) { Console.Error.WriteLine("Usage: ExportProbe CORE ALBUM_ID"); return 2; }
        BrokerProbe.Initialize();
        var connection = new Connection(args[0]);
        var ready = new ManualResetEvent(false);
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus s) {
            if (s.ToString() == "Connected") ready.Set();
        };
        try {
            connection.Connect();
            if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");
            var response = Request(connection, new ExportRequest { MediaIds = new[] { Id(args[1]) } });
            Console.WriteLine("CMEXPORTTYPE\t" + response.GetType().FullName);
            Console.WriteLine("CMEXPORT\t" + response);
            var prepared = Request(connection, new ExportAlbumRequest { MediaId = Id(args[1]) }) as ExportResponse;
            if (prepared == null) throw new InvalidOperationException("Unexpected prepared export response.");
            Console.WriteLine("CMPREPTYPE\t" + prepared.GetType().FullName);
            foreach (var pkg in prepared.MetadataPackages) {
                Console.WriteLine("CMPKG\t" + pkg.MediaId + "\t" + pkg.Name + "\t" + pkg.Items.Count);
                foreach (var item in pkg.Items) {
                    Console.WriteLine("CMITEM\t" + item.MediaId + "\t" + item.Name + "\t" + item.MediaFiles.Count);
                    foreach (var mf in item.MediaFiles)
                        Console.WriteLine("CMFILE\t" + mf.Name + "\t" + mf.Size + "\t" + mf.Url + "\t" + mf.IsBrokerInternal);
                }
            }
            return 0;
        } catch (Exception error) {
            Console.Error.WriteLine("CMERROR\t" + error.Message); return 1;
        } finally { connection.Disconnect(); }
    }
}
