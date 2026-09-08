using System;
using System.Threading;
using Sooloos.Broker;
using Sooloos.Msg.Import;

internal static class ProjectCleanup {
    public static int Main(string[] args) {
        if (args.Length != 2) return 2;
        BrokerProbe.Initialize();
        var c = new Connection(args[0]);
        var ready = new ManualResetEvent(false);
        var done = new ManualResetEvent(false);
        int result = 1;
        c.ConnectionStatusChanged += delegate(IConnection x, ConnectionStatus s) {
            if (s.ToString() == "Connected") ready.Set();
        };
        try {
            c.Connect();
            if (!ready.WaitOne(10000)) return 1;
            c.Message.SendRequest(new ImportProjectRemoveRequest { ProjectId = Guid.Parse(args[1]) },
                delegate(IMessage m, bool final) {
                    Console.WriteLine(m);
                    if (m is Sooloos.Msg.Common.SuccessResponse) result = 0;
                    if (final) done.Set();
                });
            done.WaitOne(10000);
            return result;
        } finally { c.Disconnect(); }
    }
}
