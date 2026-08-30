'use strict';

// Gera o icone da bandeja em tempo de execucao.
//
// Esta e a adaptacao mais visivel em relacao ao original. No macOS a barra de
// menu aceita texto, entao o app escreve "3 ocupadas - 1 precisa de voce" e
// pronto. A bandeja do Windows nao aceita texto nenhum: cabe um icone e um
// tooltip. Entao a informacao precisa ser desenhada - um disco colorido pela
// pior situacao presente, com a contagem por cima.
//
// O bitmap e montado a mao em BGRA porque `nativeImage.createFromBitmap` e a
// unica rota do processo principal que nao exige uma janela pra rasterizar.

const { nativeImage } = require('electron');

const SIZE = 32;

// A cor responde a mesma pergunta que o app inteiro responde: preciso voltar la?
const COLORS = {
  needsYou: [0xF5, 0x9E, 0x0B],   // ambar - alguem esta esperando por voce
  busy: [0x38, 0x7A, 0xE8],       // azul - trabalhando
  free: [0x2E, 0xA0, 0x43],       // verde - livre
  idle: [0x8A, 0x8A, 0x8A],       // cinza - nenhuma sessao
};

// Fonte 3x5. Pequena o suficiente pra caber em 32px com folga e legivel depois
// de escalada 3x.
const GLYPHS = {
  0: ['111', '101', '101', '101', '111'],
  1: ['010', '110', '010', '010', '111'],
  2: ['111', '001', '111', '100', '111'],
  3: ['111', '001', '111', '001', '111'],
  4: ['101', '101', '111', '001', '001'],
  5: ['111', '100', '111', '001', '111'],
  6: ['111', '100', '111', '101', '111'],
  7: ['111', '001', '010', '010', '010'],
  8: ['111', '101', '111', '101', '111'],
  9: ['111', '101', '111', '001', '111'],
  '+': ['000', '010', '111', '010', '000'],
};

function blankBuffer() {
  return Buffer.alloc(SIZE * SIZE * 4, 0);
}

function setPixel(buf, x, y, [r, g, b], alpha = 255) {
  if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) return;
  const i = (y * SIZE + x) * 4;
  // BGRA, pre-multiplicado nao e exigido aqui porque so usamos alpha 0 ou 255
  // nas bordas suavizadas abaixo.
  const a = alpha / 255;
  buf[i] = Math.round(b * a);
  buf[i + 1] = Math.round(g * a);
  buf[i + 2] = Math.round(r * a);
  buf[i + 3] = alpha;
}

function drawDisc(buf, color) {
  const c = (SIZE - 1) / 2;
  const radius = SIZE / 2 - 1;
  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const d = Math.hypot(x - c, y - c);
      if (d <= radius - 1) {
        setPixel(buf, x, y, color, 255);
      } else if (d <= radius) {
        // Uma borda de um pixel suavizada evita o serrilhado que faria o icone
        // parecer quebrado ao lado dos icones nativos da bandeja.
        setPixel(buf, x, y, color, Math.round(255 * (radius - d)));
      }
    }
  }
}

function drawGlyphs(buf, text, color) {
  const scale = 3;
  const glyphW = 3 * scale;
  const gap = scale;
  const totalW = text.length * glyphW + (text.length - 1) * gap;
  const startX = Math.round((SIZE - totalW) / 2);
  const startY = Math.round((SIZE - 5 * scale) / 2);

  text.split('').forEach((ch, index) => {
    const rows = GLYPHS[ch];
    if (!rows) return;
    const ox = startX + index * (glyphW + gap);
    for (let ry = 0; ry < rows.length; ry += 1) {
      for (let rx = 0; rx < rows[ry].length; rx += 1) {
        if (rows[ry][rx] !== '1') continue;
        for (let sy = 0; sy < scale; sy += 1) {
          for (let sx = 0; sx < scale; sx += 1) {
            setPixel(buf, ox + rx * scale + sx, startY + ry * scale + sy, color, 255);
          }
        }
      }
    }
  });
}

// Qual numero o icone mostra e uma decisao editorial: o que precisa de voce
// ganha de tudo, porque e a unica coisa que exige acao. Sem nada esperando,
// mostramos quantas estao trabalhando.
function chooseDisplay(counts) {
  if (counts.needsYou > 0) return { value: counts.needsYou, color: COLORS.needsYou };
  if (counts.busy > 0) return { value: counts.busy, color: COLORS.busy };
  if (counts.free > 0) return { value: counts.free, color: COLORS.free };
  return { value: 0, color: COLORS.idle };
}

function buildIcon(counts) {
  const { value, color } = chooseDisplay(counts);
  const buf = blankBuffer();
  drawDisc(buf, color);
  if (value > 0) {
    drawGlyphs(buf, value > 9 ? '+' : String(value), [255, 255, 255]);
  }
  const image = nativeImage.createFromBitmap(buf, {
    width: SIZE,
    height: SIZE,
    scaleFactor: 2,
  });
  return image;
}

// O tooltip carrega o texto que a barra de menu do macOS mostraria direto.
function buildTooltip(counts, unreported) {
  const parts = [];
  if (counts.needsYou > 0) parts.push(`${counts.needsYou} precisa de voce`);
  if (counts.busy > 0) parts.push(`${counts.busy} trabalhando`);
  if (counts.free > 0) parts.push(`${counts.free} livre${counts.free > 1 ? 's' : ''}`);
  if (parts.length === 0) parts.push('Nenhuma sessao ativa');
  if (unreported > 0) parts.push(`${unreported} sem hooks`);
  return `CodeStatus - ${parts.join(', ')}`;
}

module.exports = { buildIcon, buildTooltip, COLORS };
