using System;
using System.Threading;
using Sooloos;
using Sooloos.Broker;
using Sooloos.Msg.Zones;
using ClientZone = Sooloos.Zone;

internal static class PlaybackTool {
    static Connection connection;
    static ZoneTracker tracker;

    static Sooid Id(string text, int type) {
        var bits = text.Split(':');
        return new Sooid((byte)type, Guid.Parse(bits[bits.Length - 1]));
    }

    static ClientZone FindZone(string id) {
        var target = Id(id, 22);
        for (int i = 0; i < tracker.Count; i++) if (tracker[i].ZoneId.Equals(target)) return tracker[i];
        throw new InvalidOperationException("Playback zone not found.");
    }

    static void Connect(string host) {
        BrokerProbe.Initialize();
        connection = new Connection(host);
        var ready = new ManualResetEvent(false);
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus s) {
            if (s.ToString() == "Connected") ready.Set();
        };
        connection.Connect();
        if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");
        tracker = ZoneTracker.Instance;
        tracker.Init(connection, true);
        var deadline = DateTime.UtcNow.AddSeconds(12);
        while (tracker.Count == 0 && DateTime.UtcNow < deadline) Thread.Sleep(100);
        if (tracker.Count == 0) throw new InvalidOperationException("No playback zones were found.");
        Thread.Sleep(250);
    }

    static void Status() {
        Console.WriteLine("CMZONES\t" + tracker.Count);
        for (int i = 0; i < tracker.Count; i++) {
            var z = tracker[i];
            var state = z.Status == null ? "Unknown" : z.Status.State.ToString();
            var media = z.Status == null || z.Status.Media == null ? "" : z.Status.Media.Title;
            var subtitle = z.Status == null || z.Status.Media == null ? "" : z.Status.Media.Subtitle;
            var queueCount = z.PlayQueue == null || z.PlayQueue.Items == null ? 0 : z.PlayQueue.Items.Count;
            var queueIndex = z.Status == null || !z.Status.PlayQueueIndex.HasValue ? -1 : z.Status.PlayQueueIndex.Value;
            Console.WriteLine("CMZONE\t" + z.ZoneId + "\t" + z.Name + "\t" + state + "\t" + z.Volume +
                "\t" + z.VolumeMin + "\t" + z.VolumeMax + "\t" + z.IsMuted + "\t" + queueCount +
                "\t" + queueIndex + "\t" + media + "\t" + subtitle);
            if (z.Status != null && z.Status.AudioDevice != null) Console.WriteLine("CMAUDIO\t" + z.ZoneId + "\t" + z.Status.AudioDevice.PortNumber + "\t" + z.Status.AudioDevice.AudioPlayerInfo + "\t" + z.Status.AudioDevice.DescriptiveName + "\tpaired=" + z.Status.AudioDevice.IsPairedWithUs + "\tpairing=" + z.Status.AudioDevice.Pairing);
            if (z.PlayQueue != null && z.PlayQueue.Items != null) {
                for (int q = 0; q < z.PlayQueue.Items.Count; q++) {
                    var item = z.PlayQueue.Items[q];
                    var title = item.Media == null ? "" : item.Media.Title;
                    var sub = item.Media == null ? "" : item.Media.Subtitle;
                    Console.WriteLine("CMQUEUE\t" + z.ZoneId + "\t" + q + "\t" + item.Played + "\t" + title + "\t" + sub);
                }
            }
        }
    }

    static PlayPriority Priority(string text) {
        switch (text.ToLowerInvariant()) {
        case "now": return PlayPriority.Now;
        case "next": return PlayPriority.Next;
        case "later": return PlayPriority.Later;
        default: throw new ArgumentException("Priority must be now, next or later.");
        }
    }

    static void Transport(ClientZone z, string action) {
        switch (action.ToLowerInvariant()) {
        case "playpause": z.TransportPlayPause(); break;
        case "play": z.TransportPlay(); break;
        case "pause": z.TransportPause(); break;
        case "next": z.TransportNext(); break;
        case "previous": z.TransportPrevious(); break;
        case "stop": z.TransportStop(); break;
        default: throw new ArgumentException("Unknown transport action.");
        }
    }
    static int Run(string[] args) {
        if (args.Length < 2) return 2;
        var command = args[0];
        Connect(args[1]);
        if (command == "status") Status();
        else if (command == "transport" && args.Length == 4) Transport(FindZone(args[2]), args[3]);
        else if (command == "volume" && args.Length == 4) {
            var z = FindZone(args[2]);
            var value = int.Parse(args[3]);
            if (value < z.VolumeMin || value > z.VolumeMax) throw new ArgumentOutOfRangeException("volume");
            z.SetAudioVolume(value);
        }
        else if (command == "volume-relative" && args.Length == 4) {
            var delta = int.Parse(args[3]);
            if (delta != -1 && delta != 1) throw new ArgumentOutOfRangeException("delta");
            FindZone(args[2]).ChangeAudioVolumeRelative(delta);
        }
        else if (command == "mute" && args.Length == 4) FindZone(args[2]).SetAudioMute(bool.Parse(args[3]));
        else if (command == "pair" && args.Length == 4) FindZone(args[2]).SetPairWithUs(bool.Parse(args[3]));
        else if (command == "album" && args.Length == 5) FindZone(args[2]).PlayQueueAddAlbum(Priority(args[4]), Id(args[3], 1), false);
        else if (command == "track" && args.Length == 5) FindZone(args[2]).PlayQueueAddMedia(Priority(args[4]), new[] { Id(args[3], 3) });
        else if (command == "clear" && args.Length == 3) FindZone(args[2]).PlayQueueRemoveAll();
        else if (command == "jump" && args.Length == 4) FindZone(args[2]).PlayQueueJumpTo(int.Parse(args[3]));
        else return 2;
        if (command != "status") { Thread.Sleep(300); Console.WriteLine("CMOK\t" + command); }
        return 0;
    }

    public static int Main(string[] args) {
        try { return Run(args); }
        catch (Exception e) { Console.Error.WriteLine("CMERROR\t" + e.Message); return 1; }
        finally { if (connection != null) connection.Disconnect(); }
    }
}
