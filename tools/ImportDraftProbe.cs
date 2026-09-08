// Creates an unapproved private metadata draft, observes it, then removes it.
// Does not approve media or upload audio. Requires explicit --create-draft.
using System;
using System.Text;
using System.Threading;
using Sooloos.Broker;
using Sooloos.Msg.Import;
using Sooloos.Msg.AuxDevice;

internal static class ImportDraftProbe
{
    public static int Main(string[] args) {
        if (args.Length != 3 || args[0] != "--create-draft") {
            Console.Error.WriteLine("Usage: ImportDraftProbe --create-draft CORE_HOST TRACK.flac"); return 2;
        }
        var metadata = FlacMetadata.Load(args[2]);
        var file = new System.IO.FileInfo(args[2]);
        BrokerProbe.Initialize();
        var connection = new Connection(args[1]);
        var device = new Sooid(24, Guid.NewGuid());
        var completed = new ManualResetEvent(false);
        Guid project = Guid.Empty;
        bool owned = false;
        bool grouped = false;
        int connected = 0, registered = 0;
        connection.ConnectionStatusChanged += delegate(IConnection c, ConnectionStatus status) {
            if (status.ToString() != "Connected" || Interlocked.Exchange(ref connected, 1) != 0) return;
            connection.Message.SendRequest(new AuxDeviceConnectRequest {
                Info = new AuxDeviceInfo { DeviceId = device, Description = "ControlMac2026 import test",
                    Capabilities = new[] { Capabilities.Import }, ConfigurationType = ConfigurationType.Static },
                PingSeconds = 20
            }, delegate(IMessage response, bool final) {
                Console.WriteLine("Device response: " + response.GetType().Name);
                if (!(response is AuxDeviceConnectResponse) || Interlocked.Exchange(ref registered, 1) != 0) return;
                connection.Message.SendRequest(new CreateLooseFilesMusicProjectRequest {
                    ImportDeviceId = device,
                    CreateOptions = new[] { CreateOption.AutoSkipDuplicates, CreateOption.PreferUserMetadata, CreateOption.Private },
                    MusicFiles = new[] { new MusicFileInfo {
                        FileInfo = new Sooloos.Msg.Import.FileInfo {
                            MediaPath = Convert.ToBase64String(Encoding.UTF8.GetBytes(file.FullName)),
                            OriginalPath = file.FullName, FileSize = file.Length, IsDirectory = false },
                        ExtractedTags = metadata.Tags, CoverUrls = new string[0]
                    } }
                }, delegate(IMessage message, bool last) {
                    Console.WriteLine("Project response: " + message.GetType().Name);
                    var created = message as ProjectCreatedResponse;
                    if (created != null) {
                        project = created.ProjectId;
                        owned = !created.ProjectAlreadyExists;
                        Console.WriteLine("Draft: " + project + "; new=" + owned);
                        if (owned) connection.Message.SendRequest(new ImportProjectSubscribeRequest { ProjectId = project },
                            delegate(IMessage state, bool end) { Console.WriteLine("Draft state: " + state); });
                    }
                    if (message is ProjectCreationCompletedResponse && owned)
                        connection.Message.SendRequest(new LooseMusicFilesMakeAlbumRequest {
                            ProjectId = project,
                            MediaPaths = new[] { Convert.ToBase64String(Encoding.UTF8.GetBytes(file.FullName)) },
                            CreateOptions = new[] { CreateOption.AutoSkipDuplicates, CreateOption.PreferUserMetadata, CreateOption.Private }
                        }, delegate(IMessage grouping, bool end) {
                            Console.WriteLine("Album grouping: " + grouping);
                            grouped = grouping is Sooloos.Msg.Common.SuccessResponse;
                            if (end) completed.Set();
                        });
                });
            });
        };
        Timer ping = null;
        try {
            connection.Connect();
            ping = new Timer(delegate(object state) {
                if (registered != 0) connection.Message.SendRequest(new AuxDevicePingRequest { DeviceId = device });
            }, null, 5000, 5000);
            if (!completed.WaitOne(30000)) Console.Error.WriteLine("Draft preparation did not finish within 30 seconds.");
            return completed.WaitOne(0) && owned && grouped ? 0 : 1;
        } finally {
            if (ping != null) ping.Dispose();
            if (owned && project != Guid.Empty) {
                var removed = new ManualResetEvent(false);
                connection.Message.SendRequest(new ImportProjectRemoveRequest { ProjectId = project },
                    delegate(IMessage m, bool final) { Console.WriteLine("Draft cleanup: " + m); if (final) removed.Set(); });
                if (!removed.WaitOne(5000)) Console.Error.WriteLine("Cleanup unconfirmed for draft " + project);
            }
            connection.Disconnect();
        }
    }
}
