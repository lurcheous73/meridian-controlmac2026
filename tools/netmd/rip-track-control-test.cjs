const { WebUSB } = require('usb');
const { DevicesIds, openNewDevice } = require('netmd-js');
const { ExploitStateManager, CachedSectorControlDownload, ConsoleLogger } = require('netmd-exploits');
const fs = require('fs');
const path = require('path');

(async () => {
  let state, exploit;
  try {
    const usb = new WebUSB({ allowedDevices: DevicesIds, deviceTimeout: 30000 });
    const iface = await openNewDevice(usb);
    if (!iface) throw new Error('No NetMD device');
    const factory = await iface.factory();
    state = await ExploitStateManager.create(iface, factory, ConsoleLogger);
    console.log(`NETMD_FIRMWARE\t${state.device.versionCode}`);
    exploit = await state.require(CachedSectorControlDownload);
    console.log('NETMD_EXPLOIT\tCachedSectorControlDownload');
    const result = await exploit.downloadTrack(0, p => console.log(`NETMD_PROGRESS\t${p.action}\t${p.read}\t${p.total}`));
    const dir = path.join(process.env.HOME, 'Library/Application Support/ControlMac2026/MiniDisc Rips');
    fs.mkdirSync(dir, { recursive: true });
    const out = path.join(dir, `voyage34-track01${result.extension}`);
    fs.writeFileSync(out, Buffer.from(result.data));
    console.log(`NETMD_DONE\t${out}\t${result.data.length}`);
  } catch (e) { console.error('RIP_ERROR', e); process.exitCode = 1; }
  finally { if (state && exploit) { try { await state.unload(CachedSectorControlDownload); } catch (e) { console.error('UNLOAD_ERROR', e); } } }
  process.exit(process.exitCode || 0);
})();