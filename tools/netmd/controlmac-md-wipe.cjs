const { WebUSB } = require('usb');
const { DevicesIds, openNewDevice, listContent } = require('netmd-js');

(async () => {
  const expectedTracks = Number(process.argv[2]);
  const expectedUsed = Number(process.argv[3]);
  const expectedTitle = Buffer.from(process.argv[4] || '', 'base64').toString('utf8');
  if (!Number.isInteger(expectedTracks) || !Number.isFinite(expectedUsed)) {
    throw new Error('usage: expected-tracks expected-used expected-title-base64');
  }
  let iface = null;
  try {
    const usb = new WebUSB({ allowedDevices: DevicesIds, deviceTimeout: 15000 });
    iface = await openNewDevice(usb);
    if (!iface) throw new Error('No NetMD device found');
    const disc = await listContent(iface);
    const title = disc.title || '';
    if (!disc.writable || disc.writeProtected) throw new Error('MiniDisc is write-protected or not writable');
    if ((disc.trackCount || 0) !== expectedTracks) throw new Error('MiniDisc track count changed since confirmation');
    if ((disc.used || 0) !== expectedUsed) throw new Error('MiniDisc used-time changed since confirmation');
    if (title !== expectedTitle) throw new Error('MiniDisc title changed since confirmation');
    console.log(`CMMDWIPESTART\t${expectedTracks}\t${expectedUsed}`);
    await iface.eraseDisc();
    const after = await listContent(iface);
    if ((after.trackCount || 0) !== 0) throw new Error('Erase returned but disc still contains tracks');
    console.log('CMMDWIPEDONE');
  } finally {
    if (iface) { try { await iface.release(); } catch (_) {} }
    if (iface && iface.netMd) { try { await iface.netMd.finalize(); } catch (_) {} }
  }
})().then(() => process.exit(0)).catch(e => {
  console.error(`CMMDWIPEERROR\t${e.message || e}`);
  process.exit(1);
});
