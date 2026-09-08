// Read one known album from the Core, for post-import verification.
using System;
using System.Threading;
using Sooloos.Broker;
internal static class AlbumInspect {
    public static int Main(string[] args) {
        if (args.Length != 2) return 2;
        BrokerProbe.Initialize();
        var connection = new Connection(args[0]); var done = new ManualResetEvent(false); int result = 1;
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
            if (status.ToString() != "Connected") return;
            connection.Message.SendRequest(new Sooloos.Msg.Music.GetAlbumRequest { AlbumId = new Sooid(1, Guid.Parse(args[1])) },
                delegate(IMessage message, bool final) { Dump(message, 0); if (final) { result = message is Sooloos.Msg.Music.Album ? 0 : 1; done.Set(); } });
        };
        try { connection.Connect(); if (!done.WaitOne(20000)) return 1; return result; }
        finally { connection.Disconnect(); }
    }
    static void Dump(object value, int depth) {
        if (value == null || depth > 12) return;
        var message = value as IMessage;
        if (message != null) {
            foreach (var p in value.GetType().GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance)) {
                if (p.Name == "IsValid" || p.Name == "MessageTypeName" || p.GetIndexParameters().Length != 0) continue;
                Console.Write(new string(' ', depth) + p.Name + ": "); Dump(p.GetValue(value, null), depth + 1);
            }
        } else if (value is System.Collections.IEnumerable && !(value is string)) {
            Console.WriteLine(); foreach (var entry in (System.Collections.IEnumerable)value) Dump(entry, depth + 1);
        } else Console.WriteLine(value);
    }
}
