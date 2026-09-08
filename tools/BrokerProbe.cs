// Read-only connectivity probe using locally recovered vendor assemblies.
// Does not register an import device, create a project or upload music.
using System;
using System.Threading;
using System.Net.NetworkInformation;
using System.Collections.Concurrent;
using Sooloos.Broker;

internal static class BrokerProbe
{
    sealed class OrderedContext : SynchronizationContext {
        readonly BlockingCollection<Action> queue = new BlockingCollection<Action>();
        public OrderedContext() {
            var thread = new Thread(delegate() { foreach (var work in queue.GetConsumingEnumerable()) work(); });
            thread.IsBackground = true;
            thread.Start();
        }
        public override void Post(SendOrPostCallback callback, object state) { queue.Add(delegate { callback(state); }); }
    }
    public static void Initialize()
    {
        // Original callbacks run on one UI thread; preserve their ordering.
        SynchronizationContext.SetSynchronizationContext(new OrderedContext());
        // The shipping Mac client uses en0's MAC, via an obsolete i386 helper.
        // Supply the same real identity through the in-memory property API.
        string serial = null;
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            if (nic.Name == "en0") serial = nic.GetPhysicalAddress().ToString();
        if (serial == null || serial.Length != 12 || serial == "000000000000") {
            throw new InvalidOperationException("Cannot read en0's real network identity.");
        }
        Sooloos.SooloosProperty.CommandLine = new string[] { "--serialnumber=" + serial };
        Sooloos.Debug.ForceRealSerialNumber = false;
        Sooloos.Debug.Model = "ControlMac";
    }

    public static int Main(string[] args)
    {
        if (args.Length != 1) {
            Console.Error.WriteLine("Usage: BrokerProbe CORE_HOST");
            return 2;
        }
        Initialize();
        var done = new ManualResetEvent(false);
        var connection = new Connection(args[0]);
        int sent = 0;
        int result = 1;
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
            Console.WriteLine("Connection: " + status);
            if (status.ToString() != "Connected" || Interlocked.Exchange(ref sent, 1) != 0)
                return;
            connection.Message.SendRequest(new Sooloos.Msg.SystemInfo.GetBrokerInfoRequest(), delegate(IMessage message, bool final) {
                Console.WriteLine("Response: " + message.GetType().FullName + "; final=" + final);
                if (final) { result = message is Sooloos.Msg.SystemInfo.BrokerInfo ? 0 : 1; done.Set(); }
            });
        };
        try {
            connection.Connect();
            if (!done.WaitOne(20000)) Console.Error.WriteLine("Timed out waiting for broker info.");
        } catch (Exception error) {
            Console.Error.WriteLine(error);
        } finally {
            connection.Disconnect();
        }
        return result;
    }
}
