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
        if (args.Length != 1) return 2;
        Connection c = null;
        try {
            BrokerProbe.Initialize();
            c = new Connection(args[0]);
            var ready = new ManualResetEvent(false);
            c.ConnectionStatusChanged += delegate(IConnection x, ConnectionStatus s) { if (s.ToString() == "Connected") ready.Set(); };
            c.Connect();
            if (!ready.WaitOne(15000)) throw new TimeoutException("Could not connect to Core.");

            var broker = Request(c, new GetBrokerInfoRequest()) as BrokerInfo;
            if (broker != null) Console.WriteLine("CMCORE\t" + broker.DeviceId + "\t" + broker.Serial + "\t" + broker.SystemVersion);
            var settings = Request(c, new GetSystemSettingsRequest()) as SystemSettings;
            if (settings != null) Console.WriteLine("CMSETTINGS\t" + settings.Language + "\t" + (settings.ExtraWebPort.HasValue ? settings.ExtraWebPort.Value.ToString() : "") + "\t" + (settings.ZoneLinkResyncOften.HasValue ? settings.ZoneLinkResyncOften.Value.ToString() : ""));
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
