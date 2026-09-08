using System;
using System.Threading;
using Sooloos;
using Sooloos.Broker;

internal static class ZoneProbe {
    static Connection connection;

    public static int Main(string[] args) {
        if (args.Length != 1) return 2;
        try {
            BrokerProbe.Initialize();
            connection = new Connection(args[0]);
            var ready = new ManualResetEvent(false);
            connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus s) {
                if (s.ToString() == "Connected") ready.Set();
            };
            connection.Connect();
            if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");
            var tracker = ZoneTracker.Instance;
            tracker.Init(connection, true);
            var deadline = DateTime.UtcNow.AddSeconds(12);
            while (tracker.Count == 0 && DateTime.UtcNow < deadline) Thread.Sleep(100);
            Console.WriteLine("CMZONES\t" + tracker.Count);
            for (int i = 0; i < tracker.Count; i++) {
                var z = tracker[i];
                var state = z.Status == null ? "Unknown" : z.Status.State.ToString();
                var media = z.Status == null || z.Status.Media == null ? "" : z.Status.Media.Title;
                var subtitle = z.Status == null || z.Status.Media == null ? "" : z.Status.Media.Subtitle;
                var queueCount = z.PlayQueue == null || z.PlayQueue.Items == null ? 0 : z.PlayQueue.Items.Count;
                Console.WriteLine("CMZONE\t" + z.ZoneId + "\t" + z.Name + "\t" + state +
                    "\t" + z.Volume + "\t" + z.VolumeMin + "\t" + z.VolumeMax + "\t" + z.IsMuted +
                    "\t" + queueCount + "\t" + media + "\t" + subtitle);
                if (z.PlayQueue != null && z.PlayQueue.Items != null) {
                    for (int q = 0; q < z.PlayQueue.Items.Count; q++) {
                        var item = z.PlayQueue.Items[q];
                        var title = item.Media == null ? "" : item.Media.Title;
                        var sub = item.Media == null ? "" : item.Media.Subtitle;
                        Console.WriteLine("CMQUEUE\t" + z.ZoneId + "\t" + q + "\t" + item.Played + "\t" + title + "\t" + sub);
                    }
                }
            }
            return 0;
        } catch (Exception e) {
            Console.Error.WriteLine("CMERROR\t" + e.Message);
            return 1;
        } finally {
            if (connection != null) connection.Disconnect();
        }
    }
}
