// Client-side Windows .ico encoder. No external dependencies (keeps the page free of any
// CDN): resizes the source image to the standard icon sizes on a canvas, keeps each frame as
// a PNG (Windows Vista+ reads PNG-compressed ICO entries directly), and assembles the
// ICONDIR + ICONDIRENTRY headers by hand.

(function () {
  const ICO_SIZES = [16, 32, 48, 64, 256];

  function isIcoMagic(buf) {
    return buf.length > 4 && buf[0] === 0 && buf[1] === 0 && buf[2] === 1 && buf[3] === 0;
  }

  async function renderPngFrame(bitmap, size) {
    const canvas = document.createElement('canvas');
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, size, size);
    const scale = Math.min(size / bitmap.width, size / bitmap.height);
    const w = Math.max(1, Math.round(bitmap.width * scale));
    const h = Math.max(1, Math.round(bitmap.height * scale));
    const x = Math.floor((size - w) / 2);
    const y = Math.floor((size - h) / 2);
    ctx.drawImage(bitmap, x, y, w, h);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
    return new Uint8Array(await blob.arrayBuffer());
  }

  function assembleIco(frames, sizes) {
    const count = frames.length;
    const headerSize = 6 + 16 * count;
    let dataSize = 0;
    for (const f of frames) dataSize += f.length;
    const out = new Uint8Array(headerSize + dataSize);
    const view = new DataView(out.buffer);

    view.setUint16(0, 0, true);   // reserved
    view.setUint16(2, 1, true);   // type = icon
    view.setUint16(4, count, true);

    let offset = headerSize;
    for (let i = 0; i < count; i++) {
      const entryOffset = 6 + i * 16;
      const size = sizes[i];
      const frame = frames[i];
      out[entryOffset + 0] = size === 256 ? 0 : size; // width (0 means 256)
      out[entryOffset + 1] = size === 256 ? 0 : size; // height
      out[entryOffset + 2] = 0; // color count
      out[entryOffset + 3] = 0; // reserved
      view.setUint16(entryOffset + 4, 1, true);  // planes
      view.setUint16(entryOffset + 6, 32, true); // bit count
      view.setUint32(entryOffset + 8, frame.length, true); // bytes in resource
      view.setUint32(entryOffset + 12, offset, true);      // offset from file start
      out.set(frame, offset);
      offset += frame.length;
    }
    return out;
  }

  async function fileToIcoBytes(file) {
    const buf = new Uint8Array(await file.arrayBuffer());
    if (isIcoMagic(buf)) return buf; // already a .ico -- pass through untouched

    const bitmap = await createImageBitmap(file);
    const frames = [];
    for (const size of ICO_SIZES) {
      frames.push(await renderPngFrame(bitmap, size));
    }
    if (typeof bitmap.close === 'function') bitmap.close();
    return assembleIco(frames, ICO_SIZES);
  }

  window.MomSetupIco = { fileToIcoBytes };
})();
