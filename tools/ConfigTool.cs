using System;
using System.Threading;
using Sooloos.Broker;
using Sooloos.Msg.SystemInfo;
using Sooloos.Msg.AuxDevice;
using Sooloos.Msg.MeridianSystem;

internal static class ConfigTool {
    static string Safe(string s) { return (s ?? "").Replace('\t',' ').Replace('\n',' '); }
    static IMessage Request(Connection c, IMessage request, int timeout = 10000) {
        IMessage response = null;
        var done = new ManualResetEvent(false);
        c.Message.SendRequest(request, delegate(IMessage m, bool final) {
            if (m != null) response = m;
            if (final) done.Set();
        });
        if (!done.WaitOne(timeout)) throw new TimeoutException("Timed out waiting for " + request.GetType().Name);
        return response;
    }

    public static int Main(string[] args) {
        if (args.Length < 1) return 2;
        string host = args[0];
        string command = args.Length > 1 ? args[1].ToLowerInvariant() : "status";
        Connection c = null;
        try {
            BrokerProbe.Initialize();
            c = new Connection(host);
            var ready = new ManualResetEvent(false);
            c.ConnectionStatusChanged += delegate(IConnection x, ConnectionStatus s) { if (s.ToString() == "Connected") ready.Set(); };
            c.Connect();
            if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");

            if (command == "set-zonelink" && args.Length == 3) {
                Request(c, new SetZoneLinkResyncOften { ZoneLinkResyncOften = bool.Parse(args[2]) });
                Console.WriteLine("CMOK\tset-zonelink"); return 0;
            }
            if (command == "set-webport" && args.Length == 3) {
                int value; if (!int.TryParse(args[2], out value) || value < 1 || value > 65535) throw new ArgumentException("Web port must be 1-65535.");
                Request(c, new SetExtraWebPortRequest { ExtraWebPort = value });
                Console.WriteLine("CMOK\tset-webport"); return 0;
            }
            if (command == "set-language" && args.Length == 3) {
                Language value; if (!Enum.TryParse<Language>(args[2], true, out value)) throw new ArgumentException("Unknown language.");
                Request(c, new SetLanguageRequest { Language = value });
                Console.WriteLine("CMOK\tset-language"); return 0;
            }
            if (command != "status") throw new ArgumentException("Unknown configuration command.");

            var broker = Request(c, new GetBrokerInfoRequest()) as BrokerInfo;
            if (broker != null) Console.WriteLine("CMCORE\t" + broker.DeviceId + "\t" + broker.Serial + "\t" + broker.SystemVersion);
            var settings = Request(c, new GetSystemSettingsRequest()) as SystemSettings;
            if (settings != null) Console.WriteLine("CMSETTINGS\t" + settings.Language + "\t" + (settings.ExtraWebPort.HasValue ? settings.ExtraWebPort.Value.ToString() : "") + "\t" + (settings.ZoneLinkResyncOften.HasValue ? settings.ZoneLinkResyncOften.Value.ToString() : ""));
            var dealer = Request(c, new GetBrokerDealerInfoRequest()) as DealerInfoResponse;
            if (dealer != null) Console.WriteLine("CMDEALER\t" + Safe(dealer.DealerInfo));
            var list = Request(c, new GetAuxDeviceListRequest()) as AuxDeviceList;
            if (list != null && list.Devices != null) foreach (var d in list.Devices) {
                var md = d.Data as MeridianSystemDeviceData;
                if (md != null) {
                    Console.WriteLine("CMDEVICE\t" + d.DeviceId + "\t" + d.ConfigurationType + "\t" + Safe(md.Model) + "\t" + Safe(md.DeviceName) + "\t" + Safe(md.Serial) + "\t" + Safe(md.AudioEndpointUniqueId));
                } else {
                    Console.WriteLine("CMAUX\t" + d.DeviceId + "\t" + d.ConfigurationType + "\t" + Safe(d.Description));
                }
            }
            return 0;
        } catch (Exception e) { Console.Error.WriteLine("CMERROR\t" + e.Message); return 1; }
        finally { if (c != null) c.Disconnect(); }
    }
}
