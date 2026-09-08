const { WebUSB } = require('usb');
const { DevicesIds, openNewDevice, listContent } = require('netmd-js');

(async () => {
  let iface = null;
  try {
    const usb = new WebUSB({ allowedDevices: DevicesIds, deviceTimeout: 10000 });
    iface = await openNewDevice(usb);
    if (!iface) throw new Error('No NetMD device found');
    const deviceName = iface.netMd.getDeviceName();
    let level = 0; try { level = await iface.getNetMDLevel(); } catch (_) {}
    const hiMD = /MZ-(NH|RH|DH)|DS-HMD|CMT-AH/i.test(deviceName);
    const device = Buffer.from(deviceName || '', 'utf8').toString('base64');
    let disc;
    try { disc = await listContent(iface); }
    catch (e) {
      if (hiMD) { console.log(['CMMDHIMD', device, String(level || 0)].join('\t')); return; }
      throw e;
    }
    const title = Buffer.from(disc.title || '', 'utf8').toString('base64');
    console.log([
      'CMMDSTATUS', disc.writable ? '1' : '0', disc.writeProtected ? '1' : '0',
      String(disc.trackCount || 0), String(disc.used || 0), String(disc.left || 0),
      String(disc.total || 0), title, device, String(level || 0), hiMD ? '1' : '0'
    ].join('\t'));
  } finally {
    if (iface) { try { await iface.release(); } catch (_) {} }
    if (iface && iface.netMd) { try { await iface.netMd.finalize(); } catch (_) {} }
  }
})().then(() => process.exit(0)).catch(e => { console.error(`CMMDSTATUSERROR\t${e.message || e}`); process.exit(1); });