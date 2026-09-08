const fs = require('fs');
const { Worker } = require('worker_threads');
const { WebUSB } = require('usb');
const {
  DevicesIds, openNewDevice, prepareDownload,
  MDSession, MDTrack, Wireformat
} = require('netmd-js');
const { makeGetAsyncPacketIteratorOnWorkerThread } = require('netmd-js/dist/node-encrypt-worker');

const input = process.argv[2];
const title = process.argv[3] || 'Untitled';
const cancelPath = process.argv[4] || '';
const mode = (process.argv[5] || 'sp').toLowerCase();
const formats = { sp: Wireformat.pcm, lp2: Wireformat.lp2, lp4: Wireformat.lp4 };
if (!input || formats[mode] === undefined) throw new Error('usage: input.raw title [cancel-file] sp|lp2|lp4');

let iface = null, session = null, worker = null;
let cancelled = false, exitCode = 0;
const cancelRequested = () => !!cancelPath && fs.existsSync(cancelPath);

(async () => {
  try {
    const usb = new WebUSB({ allowedDevices: DevicesIds, deviceTimeout: 30000 });
    iface = await openNewDevice(usb);
    if (!iface) throw new Error('No NetMD device found');
    await prepareDownload(iface);
    session = new MDSession(iface);
    await session.init();    if (cancelRequested()) { cancelled = true; throw new Error('CMMD_CANCELLED'); }
    const data = fs.readFileSync(input);
    const ab = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    worker = new Worker(require.resolve('netmd-js/dist/node-encrypt-worker.js'));
    const iterator = makeGetAsyncPacketIteratorOnWorkerThread(worker);
    const track = new MDTrack(title, formats[mode], ab, 0x400, '', iterator);
    await session.downloadTrack(track, p => {
      if (cancelRequested()) { cancelled = true; throw new Error('CMMD_CANCELLED'); }
      console.log(`CMMDWRITEPROGRESS\t${p.writtenBytes}\t${p.totalBytes}`);
    });
    console.log(`CMMDWRITEDONE\t${mode}\t${title}`);
  } catch (e) {
    if (cancelled || String(e).includes('CMMD_CANCELLED')) {
      cancelled = true; exitCode = 4; console.log('CMMDWRITECANCELLED');
    } else { exitCode = 1; console.error(`CMMDWRITEERROR\t${e.stack || e}`); }
  } finally {
    if (session) { try { await session.close(); } catch (e) { console.error(`CMMDSESSIONCLOSE\t${e.message}`); } }
    if (iface) { try { await iface.release(); } catch (_) {} }
    if (iface && iface.netMd) { try { await iface.netMd.finalize(); } catch (e) { console.error(`CMMDUSBFINALIZE\t${e.message}`); } }
    if (worker) { try { await worker.terminate(); } catch (_) {} }
  }
})().then(() => process.exit(exitCode)).catch(e => { console.error(e); process.exit(1); });