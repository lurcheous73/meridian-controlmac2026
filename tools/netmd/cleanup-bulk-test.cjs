const { WebUSB } = require('usb');
const { DevicesIds, openNewDevice, readPatch, unpatch } = require('netmd-js');
const { ExploitStateManager, ConsoleLogger } = require('netmd-exploits');

(async () => {
  const usb = new WebUSB({ allowedDevices: DevicesIds, deviceTimeout: 10000 });
  const iface = await openNewDevice(usb);
  if (!iface) throw new Error('No NetMD device');
  const factory = await iface.factory();
  const state = await ExploitStateManager.create(iface, factory, ConsoleLogger);
  const total = state.getMaxPatchesAmount();
  console.log(`PATCH_SLOTS\t${total}`);
  for (let i = 0; i < total; i++) {
    const p = await readPatch(factory, i);
    console.log(`PATCH_BEFORE\t${i}\t0x${p.address.toString(16)}\t${Buffer.from(p.data).toString('hex')}`);
  }
  for (const i of [3,4,5,6]) await unpatch(factory, i, total);
  for (const i of [3,4,5,6]) {
    const p = await readPatch(factory, i);
    console.log(`PATCH_AFTER\t${i}\t0x${p.address.toString(16)}\t${Buffer.from(p.data).toString('hex')}`);
  }
  process.exit(0);
})().catch(e => { console.error('CLEANUP_ERROR', e.stack || e); process.exit(1); });
