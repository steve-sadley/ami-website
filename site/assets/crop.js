/* =============================================================================
   The photograph cropper

   A member uploads one picture and AMI needs two: a square for the profile, the
   register and the forum, and a three to one strip for the top of the membership
   card. Asking somebody to crop the same face twice is asking them to do the
   computer's job, so this takes one square from them and a band inside it for the
   card, and cuts both.

   Everything happens in the browser. The original never leaves the device, which
   means the location and the camera buried in a phone photograph never leave it
   either. That is the main reason for doing it here rather than on the server,
   and it is worth more than the bandwidth it saves.

   Because the browser produced the file, the Worker still checks it on arrival.
   A file this code made and a file somebody posted by hand are the same thing to
   an endpoint, and only one of them is trustworthy.
   ============================================================================= */

/* Apple draws the strip on a store card at 375 by 123 points, which is 1125 by
   369 at 3x. The band on screen uses the same proportion rather than a round 3 to
   1, so what a member lines up is exactly what the card shows. */
const CROP_STRIP_W = 1125;
const CROP_STRIP_H = 369;
const CROP_SQUARE  = 1024;
const CROP_MIN     = 600;     // pixels on the short side, below which a card looks soft
const CROP_QUALITY = 0.86;

function makeCropper(opts){
  const stage = opts.stage;
  const cv    = opts.canvas;
  const band  = opts.band;
  const zoom  = opts.zoom;
  const bandy = opts.bandy;
  const prev  = opts.previews || {};
  const onchange = opts.onchange || (() => {});
  const ctx   = cv.getContext('2d');
  const F     = cv.width;
  const BH    = Math.round(F * CROP_STRIP_H / CROP_STRIP_W);

  let img = null, base = 1, scale = 1, ox = 0, oy = 0, by = 0.30;

  /* ---------- placing it ---------- */
  function fit(){
    // Cover, never letterbox. A frame with a grey wedge in it is a frame the
    // member will try to fix and cannot.
    base  = Math.max(F / img.width, F / img.height);
    scale = base;
    ox = (F - img.width  * scale) / 2;
    oy = (F - img.height * scale) / 2;
    by = 0.30;
    if (zoom)  zoom.value = 100;
    if (bandy) bandy.value = 30;
    clamp();
    draw();
  }

  // The image may never pull away from an edge, at any scale, after any drag.
  function clamp(){
    const w = img.width * scale, h = img.height * scale;
    ox = Math.min(0, Math.max(F - w, ox));
    oy = Math.min(0, Math.max(F - h, oy));
  }

  const bandTop = () => by * (F - BH);

  /* THE PANEL. This is the thing that makes the card work.

     A wallet pass writes the member's name across the strip, in white, wherever
     Apple decides, and nothing may sit between the lettering and the picture. A
     member photographed against a white studio background therefore got a white
     name on a white ground, unreadable from the fourth letter on.

     Darkening the whole picture enough to carry white lettering took the lower
     half of the face with it. Taking the name off the picture altogether was
     legal, verified, correctly signed, and refused by iOS without a word.

     So the darkness is COMPOSED rather than washed: a graphite panel down the
     left, where the lettering lands, and the photograph to the right of it with
     nothing over the face at all. The picture is drawn shifted right by half the
     panel width so the subject moves out from behind it, which is also why the
     preview on /photo shows the panel: a member positioning their picture can
     see what the card will be.

     IT IS NOT IN USE. The panel was built on 23 August and abandoned the same
     afternoon: Apple draws the name wider than any panel narrow enough to leave
     the face alone, so "Steve Sadley" ran straight off the graphite and across
     the picture. The name went below the strip instead. Kept here rather than
     deleted because the composition is sound and the next idea that needs a
     solid ground inside the picture starts from it. Pass panel = true to cut().

     PANEL is the fraction of the strip the graphite covers before it starts to
     clear. FADE is how much of the width it takes to disappear. */
  const PANEL = 0.42;
  const FADE  = 0.16;

  function paintPanel(g, w, h){
    const grad = g.createLinearGradient(0, 0, w, 0);
    grad.addColorStop(0,            'rgba(18,21,27,1)');
    grad.addColorStop(PANEL,        'rgba(18,21,27,1)');
    grad.addColorStop(PANEL + FADE * 0.45, 'rgba(18,21,27,.72)');
    grad.addColorStop(PANEL + FADE, 'rgba(18,21,27,0)');
    g.fillStyle = grad;
    g.fillRect(0, 0, w, h);
  }

  /* The wash, painted INTO the picture rather than laid over it, because the
     picture is the only surface the site card and the wallet pass share. The
     site's own `.strip::after` was removed at the same time, or the gradient
     would be applied twice and the face would go to black. */
  function paintWash(g, w, h){
    const grad = g.createLinearGradient(0, 0, 0, h);
    // Light, because NOTHING is written over it any more. An earlier version had
    // to be dark enough by half height to carry white lettering over a white
    // studio background, and the result took the lower half of the face with it.
    // Steve looked at four fronts on 23 August and chose the one where the name
    // moves off the picture, which is what makes this able to be gentle.
    //
    // It is not nothing, either. It settles the foot of the strip into the card
    // rather than meeting the fields row on a bright edge, and it does the same
    // job whether the photograph is dark or blown out.
    grad.addColorStop(0, 'rgba(10,12,16,.04)');
    grad.addColorStop(1, 'rgba(10,12,16,.30)');
    g.fillStyle = grad;
    g.fillRect(0, 0, w, h);
  }

  function draw(){
    ctx.clearRect(0, 0, F, F);
    if (!img) { onchange(false); return; }
    ctx.drawImage(img, ox, oy, img.width * scale, img.height * scale);

    if (band) {
      band.style.top    = (bandTop() / F * 100) + '%';
      band.style.height = (BH / F * 100) + '%';
      band.style.display = 'block';
    }

    // The previews carry the same transform at their own size, so there is no
    // second idea of where the crop is and nothing to keep in step.
    [prev.square, prev.small].forEach(c => {
      if (!c) return;
      const k = c.width / F, g = c.getContext('2d');
      g.clearRect(0, 0, c.width, c.height);
      g.drawImage(img, ox * k, oy * k, img.width * scale * k, img.height * scale * k);
    });
    if (prev.strip) {
      const c = prev.strip, k = c.width / F, g = c.getContext('2d');
      g.clearRect(0, 0, c.width, c.height);
      g.drawImage(img, ox * k, (oy - bandTop()) * k,
                  img.width * scale * k, img.height * scale * k);
      // The same wash the saved file gets, so the preview is what is saved
      // rather than a flattering version of it.
      paintWash(g, c.width, c.height);
    }
    onchange(true);
  }

  /* ---------- moving it ---------- */
  let dragging = false, lx = 0, ly = 0;
  if (stage) {
    stage.addEventListener('pointerdown', e => {
      if (!img) return;
      dragging = true; lx = e.clientX; ly = e.clientY;
      stage.classList.add('drag');
      stage.setPointerCapture(e.pointerId);
    });
    stage.addEventListener('pointermove', e => {
      if (!dragging) return;
      const k = F / stage.clientWidth;         // css pixels to canvas pixels
      ox += (e.clientX - lx) * k;
      oy += (e.clientY - ly) * k;
      lx = e.clientX; ly = e.clientY;
      clamp(); draw();
    });
    ['pointerup','pointercancel','pointerleave'].forEach(t =>
      stage.addEventListener(t, () => { dragging = false; stage.classList.remove('drag'); }));
  }

  if (zoom) zoom.addEventListener('input', () => {
    if (!img) return;
    // Hold whatever is in the middle of the frame while the scale changes, or
    // scaling walks the face out of shot and the member has to chase it.
    const cx = (F / 2 - ox) / scale, cy = (F / 2 - oy) / scale;
    scale = base * (zoom.value / 100);
    ox = F / 2 - cx * scale;
    oy = F / 2 - cy * scale;
    clamp(); draw();
  });

  if (bandy) bandy.addEventListener('input', () => { by = bandy.value / 100; draw(); });

  /* ---------- loading one ---------- */
  // createImageBitmap with from-image is what applies the orientation a phone
  // writes into the file rather than into the pixels. Without it a picture taken
  // in portrait arrives on its side.
  async function decode(src){
    if (src instanceof Blob && 'createImageBitmap' in window) {
      try { return await createImageBitmap(src, { imageOrientation: 'from-image' }); }
      catch (e) { /* fall through to the img path */ }
    }
    return await new Promise((res, rej) => {
      const i = new Image();
      i.onload  = () => res(i);
      i.onerror = () => rej(new Error('That file could not be opened as a picture.'));
      i.src = src instanceof Blob ? URL.createObjectURL(src) : src;
    });
  }

  async function load(src){
    const i = await decode(src);
    const w = i.width, h = i.height;
    if (Math.min(w, h) < CROP_MIN) {
      const e = new Error('That picture is ' + w + ' by ' + h + ' pixels. It needs to be at '
        + 'least ' + CROP_MIN + ' on the short side, or it will look soft on your card.');
      e.tooSmall = true;
      throw e;
    }
    img = i;
    fit();
  }

  /* ---------- cutting it ---------- */
  /* The square comes out as a JPEG and the strip as a PNG, and the difference
     matters. The strip is the one picture that leaves this site inside an Apple
     Wallet pass, and a pass carries PNG: a JPEG named strip.png is refused by
     iOS with no explanation at all. The square is only ever shown in a browser,
     so it stays a JPEG and stays small. A PNG strip is bigger, and that is the
     price of the card working. */
  function cut(w, h, sy, type = 'image/jpeg', wash = false, panel = false){
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const g = c.getContext('2d');
    // Black underneath rather than transparent, because JPEG has no transparency
    // and an unpainted pixel comes out black anyway. Saying so is better than
    // finding out.
    g.fillStyle = '#0f1116';
    g.fillRect(0, 0, w, h);
    const k = w / F;
    g.imageSmoothingQuality = 'high';
    // Shifted right by half the panel, so the subject steps out from behind it
    // rather than being half covered by it.
    const shift = panel ? w * PANEL * 0.5 : 0;
    g.drawImage(img, ox * k + shift, (oy - sy) * k,
                img.width * scale * k, img.height * scale * k);
    if (panel) paintPanel(g, w, h);
    if (wash)  paintWash(g, w, h);
    // The quality argument is ignored for PNG, which is lossless.
    return new Promise(res => c.toBlob(res, type, CROP_QUALITY));
  }

  async function cutBoth(){
    if (!img) throw new Error('There is no picture to save yet.');
    const [square, strip] = await Promise.all([
      // The square is never written over, so it keeps the picture as taken.
      cut(CROP_SQUARE, CROP_SQUARE, 0, 'image/jpeg', false, false),
      cut(CROP_STRIP_W, CROP_STRIP_H, bandTop(), 'image/png', true, false),
    ]);
    return { square, strip };
  }

  return {
    load, cutBoth,
    reset: () => { if (img) fit(); },
    has:   () => !!img,
    // For the tests, and for anything that later wants to remember where a member
    // put the crop so a second visit starts where they left it.
    state: () => ({ scale: scale / base, ox, oy, by }),
  };
}
