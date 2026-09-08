const fs = require('fs');
const { execFileSync } = require('child_process');
const { Worker } = require('worker_threads');
const { WebUSBDevice, findByIds } = require('usb');
const {
  DevicesIds, UMSCHiMDFilesystem, HiMD,
  HiMDSecureSession, uploadMacDependent,
  generateCodecInfo
} = require('himd-js');
const { makeAsyncWorker } = require('himd-js/dist/node-crypto-worker');

const mode = process.argv[2] || 'status';
const input = process.argv[3] || '';
const title = process.argv[4] || 'Untitled';
const album = process.argv[5] || '';
const artist = process.argv[6] || '';
const cancelPath = process.argv[7] || '';

const b64 = s => Buffer.from(s || '', 'utf8').toString('base64');
const cancelled = () => cancelPath && fs.existsSync(cancelPath);
function unmountMatching(vid, pid) {
  if (process.platform !== 'darwin') return;
  let out = '';
  try { out = execFileSync('/usr/sbin/system_profiler', ['SPUSBDataType'], { encoding: 'utf8' }); }
  catch (_) { return; }
  let curVid = '', curPid = '', bsd = '';
  for (const raw of out.split(/\r?\n/)) {
    const line = raw.trim();
    let m = line.match(/^Vendor ID:\s*0x([0-9a-f]+)/i); if (m) curVid = m[1].toLowerCase();
    m = line.match(/^Product ID:\s*0x([0-9a-f]+)/i); if (m) curPid = m[1].toLowerCase();
    m = line.match(/^BSD Name:\s*(disk\S+)/i); if (m) bsd = m[1];
    if (bsd && curVid === vid.toString(16).padStart(4,'0') && curPid === pid.toString(16).padStart(4,'0')) {
      try { execFileSync('/usr/sbin/diskutil', ['unmountDisk', '/dev/' + bsd], { stdio: 'ignore' }); } catch (_) {}
      bsd = '';
    }
  }
}

async function openHiMD() {
  let legacy = null, spec = null;
  for (const d of DevicesIds) { legacy = findByIds(d.vendorId, d.deviceId); if (legacy) { spec = d; break; } }
  if (!legacy || !spec) throw new Error('No Hi-MD device found');
  unmountMatching(spec.vendorId, spec.deviceId);
  legacy.open();
  const iface = legacy.interface(0);
  try { if (iface.isKernelDriverActive()) iface.detachKernelDriver(); } catch (_) {}
  const web = await WebUSBDevice.createInstance(legacy);
  await web.open();
  const hfs = new UMSCHiMDFilesystem(web);
  await hfs.init(false);
  const himd = await HiMD.init(hfs);
  return { legacy, iface, web, hfs, himd, spec };
}

(async () => {
  let ctx = null, session = null, worker = null;
  try {
    ctx = await openHiMD();
    const stats = await ctx.hfs.statFilesystem();
    const deviceName = ctx.hfs.getName();
    const discTitle = ctx.himd.getDiscTitle() || '';
    const trackCount = ctx.himd.getTrackCount();
    if (mode === 'status') {
      console.log(['CMHIMDSTATUS', b64(deviceName), b64(discTitle), String(trackCount),
        String(stats.used), String(stats.left), String(stats.total)].join('\t'));
      return;
    }
    if (mode !== 'write') throw new Error('Unknown Hi-MD helper mode');
    if (!input || !fs.existsSync(input)) throw new Error('Prepared Hi-MD PCM file missing');
    if (cancelled()) { console.log('CMHIMDCANCELLED'); process.exitCode = 4; return; }
    const data = fs.readFileSync(input);
    if (!data.length || data.length % 4 !== 0) throw new Error('Invalid 16-bit stereo PCM payload');
    if (data.length + 2 * 1024 * 1024 > stats.left) throw new Error('Not enough free Hi-MD capacity');

    const stream = await ctx.himd.openWriteStream();
    session = new HiMDSecureSession(ctx.himd, ctx.hfs.driver);
    await session.performAuthentication();
    worker = new Worker(require.resolve('himd-js/dist/node-crypto-worker.js'));
    const crypto = await makeAsyncWorker(worker);
    const codecInfo = generateCodecInfo('PCM', 0);
    const ab = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    await uploadMacDependent(ctx.himd, session, stream, ab, codecInfo,
      { title, album, artist }, ({ byte, totalBytes }) => {
        console.log(`CMHIMDPROGRESS\t${byte}\t${totalBytes}`);
      }, crypto, true);

    await session.finalizeSession(); session = null;
    await ctx.himd.flush();
    console.log(`CMHIMDDONE\t${b64(title)}`);
  } catch (e) {
    console.error(`CMHIMDERROR\t${e && (e.stack || e.message) ? (e.stack || e.message) : e}`);
    process.exitCode = process.exitCode || 1;
  } finally {
    if (session) { try { await session.finalizeSession(); } catch (_) {} }
    if (worker) { try { await worker.terminate(); } catch (_) {} }
    if (ctx && ctx.hfs && ctx.hfs.driver) { try { await ctx.hfs.driver.close(); } catch (_) {} }
    if (ctx && ctx.legacy) { try { ctx.legacy.close(); } catch (_) {} }
  }
})().catch(e => { console.error(`CMHIMDERROR\t${e.stack || e}`); process.exit(1); });
