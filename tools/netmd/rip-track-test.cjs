const fs = require('fs');
const path = require('path');
const { WebUSB } = require('usb');
const { DevicesIds, openNewDevice } = require('netmd-js');
const { AtracRecovery, getBestSuited, ExploitStateManager, ConsoleLogger } = require('netmd-exploits');

(async () => {
  const out = process.argv[2] || path.join(process.env.HOME, 'Library/Caches/ControlMac2026/netmd-track-01');
  const usb = new WebUSB({ allowedDevices: DevicesIds, deviceTimeout: 1000000 });
  const iface = await openNewDevice(usb);
  if (!iface) throw new Error('No NetMD device found');
  const factory = await iface.factory();
  const state = await ExploitStateManager.create(iface, factory, ConsoleLogger);
  console.log(`NETMD_FIRMWARE\t${state.device.versionCode}`);
  const Impl = getBestSuited(AtracRecovery, state.device);
  if (!Impl) throw new Error(`No ATRAC recovery exploit for ${state.device.versionCode}`);
  console.log(`NETMD_EXPLOIT\t${Impl._name}`);
  const exploit = await state.require(Impl);
  const result = await exploit.downloadTrack(0, p => console.log(`NETMD_PROGRESS\t${p.action}\t${p.read}\t${p.total}`));
  const outfile = out + '.' + result.extension;
  fs.writeFileSync(outfile, Buffer.from(result.data));
  console.log(`NETMD_RIPPED\t${outfile}\t${result.data.length}`);
  await state.unload(Impl);
  process.exit(0);
})().catch(e => { console.error('NETMD_ERROR', e && e.stack || e); process.exit(1); });
